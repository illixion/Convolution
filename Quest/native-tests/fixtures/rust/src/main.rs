//! make-fixtures <out.vgat>: the same flow pairs and disparities as the Swift
//! generator, written by vergence-worker's record code.
#![allow(dead_code)]

#[path = "../../../../../../vergence/worker/src/preprocess.rs"]
mod preprocess;
#[path = "../../../../../../vergence/worker/src/record.rs"]
mod record;

use record::{EYE_MONO, EYE_RIGHT, KIND_DISPARITY, KIND_FLOW_PAIR, Record, Time, track_header};

fn flow(c: usize, x: usize, y: usize, pair: usize) -> f32 {
    if c < 4 { (c + 1) as f32 * 0.75 + x as f32 * 0.5 - y as f32 * 0.25 + pair as f32 } else { (x + y) as f32 / 12.0 }
}

fn disparity(x: usize, y: usize, frame: usize) -> f32 {
    -2.0 + x as f32 * 0.5 + y as f32 * 0.25 + frame as f32 * 0.1
}

fn main() {
    let out = std::env::args().nth(1).expect("usage: make-fixtures <out.vgat>");
    let (fw, fh, dw, dh) = (8, 5, 6, 4);
    let models = [("flowPair".to_string(), "fixture".to_string())].into_iter().collect();
    let mut track = track_header("fixture", "vergence-worker fixture", &models, 64, 32);
    let time = |frame: usize| Time { value: frame as i64 * 1001, timescale: 24000 };
    for frame in 0..4 {
        let d: Vec<f32> = (0..dh).flat_map(|y| (0..dw).map(move |x| disparity(x, y, frame))).collect();
        track.extend(Record::int16(&d, KIND_DISPARITY, EYE_RIGHT, 1, dw, dh, time(frame), time(frame), 8.0).deflated().framed());
        if frame < 3 {
            let f: Vec<f32> =
                (0..5).flat_map(|c| (0..fh).flat_map(move |y| (0..fw).map(move |x| flow(c, x, y, frame)))).collect();
            track.extend(Record::int16(&f, KIND_FLOW_PAIR, EYE_MONO, 5, fw, fh, time(frame), time(frame + 1), 16.0).deflated().framed());
        }
    }
    std::fs::write(out, track).expect("writing the track");
}
