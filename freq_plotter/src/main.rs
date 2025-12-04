mod measurements;

use crate::measurements::MeasurementWindow;
use anyhow::Result;
use clap::Parser;
use eframe::egui;
use eframe::egui::plot::{Line, Plot, Legend};
use serialport;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tracing::{error, info};
use tracing_subscriber::FmtSubscriber;

/// 命令行参数：配置串口、参考时钟等
#[derive(Parser, Debug)]
#[clap(author, version, about = "FPGA 频率实时曲线显示")]
struct Args {
    /// 窗口长度（秒），显示最近多少秒的数据
    #[clap(short, long, default_value_t = 10)]
    window_sec: usize,

    /// 串口设备
    #[clap(long, default_value = "/dev/cu.usbserial-0001")]
    port: String,

    /// 波特率
    #[clap(long, default_value_t = 115200)]
    baud: u32,

    /// 参考时钟频率 Hz（用于 f = N * clk / C）
    #[clap(long, default_value_t = 200_000_000.0)]
    clk: f64,
}

struct MonitorApp {
    measurements: Arc<Mutex<MeasurementWindow>>,
}

impl MonitorApp {
    fn new(window_sec: usize) -> Self {
        // 两个通道：粗频率 & 粗+细频率
        let window = MeasurementWindow::new_with_channels(
            window_sec,
            vec!["freq_coarse".to_string(), "freq_tdl".to_string()],
        );
        Self {
            measurements: Arc::new(Mutex::new(window)),
        }
    }
}

impl eframe::App for MonitorApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let (series, _latest) = if let Ok(guard) = self.measurements.lock() {
            (guard.plot_series(), guard.latest_points())
        } else {
            (Vec::new(), Vec::new())
        };

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("FPGA 互易频率计数 - 实时曲线");
            ui.label("数据源: 串口 R=NNNNNN,CCCCCC[,FF] 行；");
            ui.label("freq_coarse = N * clk / C,  freq_tdl ≈ N / ((C + frac(F)) / clk)");
            ui.add_space(8.0);

            Plot::new("freq_plot")
                .legend(Legend::default())
                .allow_scroll(false)
                .allow_zoom(true)
                .show(ui, |plot_ui| {
                for (name, points) in series {
                    plot_ui.line(Line::new(points).name(name));
                }
                });
        });

        ctx.request_repaint();
    }
}

fn spawn_uart_thread(
    monitor_ref: Arc<Mutex<MeasurementWindow>>,
    port: String,
    baud: u32,
    clk_hz: f64,
) {
    thread::spawn(move || {
        if let Err(err) = uart_loop(monitor_ref, &port, baud, clk_hz) {
            error!("UART 采集线程退出: {err:#}");
        }
    });
}

fn uart_loop(
    monitor_ref: Arc<Mutex<MeasurementWindow>>,
    port: &str,
    baud: u32,
    clk_hz: f64,
) -> Result<()> {
    use anyhow::Context;

    let mut sp = serialport::new(port, baud)
        .timeout(Duration::from_millis(200))
        .open()
        .with_context(|| format!("打开串口 {port} 失败"))?;

    info!("串口已打开: {port} @ {baud} baud, clk={clk_hz} Hz");

    let mut buf: Vec<u8> = Vec::with_capacity(1024);
    let mut tmp = [0u8; 256];
    let t0 = Instant::now();

    loop {
        match sp.read(&mut tmp) {
            Ok(0) => {
                // 没数据，稍等一下
                thread::sleep(Duration::from_millis(10));
                continue;
            }
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {
                continue;
            }
            Err(e) => return Err(anyhow::anyhow!("串口读取失败: {e}")),
        }

        // 按换行解析多行
        loop {
            if let Some(pos) = buf.iter().position(|&b| b == b'\n') {
                let line_bytes = buf.drain(..=pos).collect::<Vec<u8>>();
                let line_str = String::from_utf8_lossy(&line_bytes);
                let text = line_str.trim();

                if let Some((n_cycles, c_coarse, f_fine)) = parse_recip_line(text) {
                    if n_cycles > 0 && c_coarse > 0 {
                        // 粗频率
                        let f_coarse = n_cycles as f64 * clk_hz / (c_coarse as f64);

                        // 细时间修正：
                        //   - 假定 fine_raw 在 [F_MIN, F_MAX] 间近似线性分布；
                        //   - 将 F 映射到 [0, 1) 的 frac(F)；
                        //   - T_est ≈ (C + frac(F)) / clk_hz, f_tdl ≈ N / T_est。
                        //
                        // 这里先用实验阶段固定参数，可根据 TDL 实测分布调整。
                        const F_MIN: f64 = 0.0;
                        const F_MAX: f64 = 21.0; // 对应 0x15，在 50MHz 诊断中观测到
                        let frac_f = if f_fine >= F_MIN && f_fine <= F_MAX {
                            (f_fine - F_MIN) / (F_MAX - F_MIN + 1.0)
                        } else {
                            0.0
                        };

                        let c_plus_frac = (c_coarse as f64) + frac_f;
                        let t_est = c_plus_frac / clk_hz;
                        let f_tdl = n_cycles as f64 / t_est;

                        let t_sec = t0.elapsed().as_secs_f64();

                        if let Ok(mut win) = monitor_ref.lock() {
                            win.add_row(t_sec, &[f_coarse, f_tdl]);
                        }
                    }
                }
            } else {
                break;
            }
        }
    }
}

/// 解析 "R=NNNNNN,CCCCCC" 或 "R=NNNNNN,CCCCCC,FF" 行
/// 返回 (N, C, F)，其中 F 为 fine_raw 的数值（若没有则为 0）
fn parse_recip_line(text: &str) -> Option<(u32, u32, f64)> {
    if !text.starts_with("R=") {
        return None;
    }
    let body = &text[2..];
    // 兼容两种格式：
    //   R=NNNNNN,CCCCCC
    //   R=NNNNNN,CCCCCC,FF
    let mut parts = body.split(',').map(|s| s.trim());
    let n_hex = parts.next()?;
    let c_hex = parts.next()?;
    let fine_hex_opt = parts.next();

    let n_cycles = u32::from_str_radix(n_hex, 16).ok()?;
    let c_coarse = u32::from_str_radix(c_hex, 16).ok()?;

    let f_fine = if let Some(fh) = fine_hex_opt {
        u32::from_str_radix(fh, 16).ok().map(|v| v as f64).unwrap_or(0.0)
    } else {
        0.0
    };

    Some((n_cycles, c_coarse, f_fine))
}

fn main() -> Result<()> {
    let args = Args::parse();

    let subscriber = FmtSubscriber::builder()
        .with_max_level(tracing::Level::INFO)
        .finish();
    tracing::subscriber::set_global_default(subscriber)
        .expect("setting default subscriber failed");

    let mut app = MonitorApp::new(args.window_sec);

    let monitor_ref = app.measurements.clone();
    spawn_uart_thread(monitor_ref, args.port.clone(), args.baud, args.clk);

    info!(
        "启动 GUI：窗口={}s, 串口={}, 波特率={}, clk={} Hz, 通道=freq_coarse,freq_tdl",
        args.window_sec, args.port, args.baud, args.clk
    );

    let native_options = eframe::NativeOptions::default();
    let mut initial_app = Some(app);

    eframe::run_native(
        "FPGA 频率实时监视器",
        native_options,
        Box::new(move |_cc| {
            Box::new(
                initial_app
                    .take()
                    .expect("MonitorApp should only be constructed once"),
            )
        }),
    );

    Ok(())
}
