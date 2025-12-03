use std::collections::VecDeque;

pub type Measurement = egui::plot::PlotPoint;

#[derive(Debug)]
pub struct MeasurementWindow {
    pub(crate) channel_names: Vec<String>,
    values: Vec<VecDeque<Measurement>>,
    look_behind: f64,
    last_x: Option<f64>,
}

impl MeasurementWindow {
    pub fn new_with_channels(look_behind: usize, channel_names: Vec<String>) -> Self {
        let count = channel_names.len().max(1);
        Self {
            channel_names: if channel_names.is_empty() {
                vec!["signal".to_string()]
            } else {
                channel_names
            },
            values: (0..count).map(|_| VecDeque::new()).collect(),
            look_behind: look_behind as f64,
            last_x: None,
        }
    }

    pub fn add_row(&mut self, x: f64, samples: &[f64]) {
        if samples.len() != self.values.len() {
            return;
        }

        if let Some(last) = self.last_x {
            if x < last {
                self.clear_all();
            }
        }
        self.last_x = Some(x);

        for (deque, &y) in self.values.iter_mut().zip(samples.iter()) {
            deque.push_back(Measurement::new(x, y));
        }

        self.trim_old_points(x);
    }

    fn clear_all(&mut self) {
        for deque in self.values.iter_mut() {
            deque.clear();
        }
    }

    fn trim_old_points(&mut self, newest_x: f64) {
        let limit = newest_x - self.look_behind;
        for deque in self.values.iter_mut() {
            while let Some(front) = deque.front() {
                if front.x >= limit {
                    break;
                }
                deque.pop_front();
            }
        }
    }

    pub fn plot_series(&self) -> Vec<(String, egui::plot::PlotPoints)> {
        self.channel_names
            .iter()
            .cloned()
            .zip(self.values.iter())
            .map(|(name, deque)| {
                (
                    name,
                    egui::plot::PlotPoints::Owned(Vec::from_iter(deque.iter().copied())),
                )
            })
            .collect()
    }

    pub fn latest_points(&self) -> Vec<Option<Measurement>> {
        self.values
            .iter()
            .map(|deque| deque.back().copied())
            .collect()
    }
}

#[cfg(test)]
mod test {
    use super::*;

    fn single_channel_window() -> MeasurementWindow {
        MeasurementWindow::new_with_channels(100, vec!["signal".to_string()])
    }

    #[test]
    fn empty_measurements() {
        let w = MeasurementWindow::new_with_channels(123, vec!["one".into(), "two".into()]);
        assert_eq!(w.channel_names, vec!["one".to_string(), "two".to_string()]);
        assert!(w.values.iter().all(|deque| deque.is_empty()));
    }

    #[test]
    fn appends_one_value() {
        let mut w = single_channel_window();

        w.add_row(10.0, &[20.0]);
        assert_eq!(w.values[0].len(), 1);
        assert_eq!(
            w.values[0].back().copied(),
            Some(Measurement::new(10.0, 20.0))
        );
    }

    #[test]
    fn clears_on_out_of_order() {
        let mut w = single_channel_window();

        w.add_row(10.0, &[20.0]);
        w.add_row(20.0, &[30.0]);
        w.add_row(19.0, &[100.0]);
        assert_eq!(w.values[0].len(), 1);
        assert_eq!(
            w.values[0].back().copied(),
            Some(Measurement::new(19.0, 100.0))
        );
    }

    #[test]
    fn trims_to_look_behind_window() {
        let mut w = single_channel_window();

        for x in 0..=20 {
            w.add_row((x as f64) * 10.0, &[x as f64]);
        }

        let collected: Vec<_> = w.values[0].iter().copied().collect();
        assert_eq!(
            collected,
            vec![
                Measurement::new(100.0, 10.0),
                Measurement::new(110.0, 11.0),
                Measurement::new(120.0, 12.0),
                Measurement::new(130.0, 13.0),
                Measurement::new(140.0, 14.0),
                Measurement::new(150.0, 15.0),
                Measurement::new(160.0, 16.0),
                Measurement::new(170.0, 17.0),
                Measurement::new(180.0, 18.0),
                Measurement::new(190.0, 19.0),
                Measurement::new(200.0, 20.0),
            ]
        );
    }

    #[test]
    fn multi_channel_updates_all_series() {
        let mut w =
            MeasurementWindow::new_with_channels(100, vec!["a".into(), "b".into(), "c".into()]);

        w.add_row(1.0, &[1.0, 2.0, 3.0]);
        w.add_row(2.0, &[2.0, 3.0, 4.0]);

        let a: Vec<_> = w.values[0].iter().copied().collect();
        let b: Vec<_> = w.values[1].iter().copied().collect();
        let c: Vec<_> = w.values[2].iter().copied().collect();

        assert_eq!(
            a,
            vec![Measurement::new(1.0, 1.0), Measurement::new(2.0, 2.0)]
        );
        assert_eq!(
            b,
            vec![Measurement::new(1.0, 2.0), Measurement::new(2.0, 3.0)]
        );
        assert_eq!(
            c,
            vec![Measurement::new(1.0, 3.0), Measurement::new(2.0, 4.0)]
        );
    }
}
