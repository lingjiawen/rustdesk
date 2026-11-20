use base::message_proto::{Message, VoiceCallRequest, VoiceCallResponse};
use hbb_common::get_time;
use scrap::CodecFormat;
use std::collections::HashMap;

#[derive(Debug, Default)]
pub struct QualityStatus {
    pub speed: Option<String>,
    pub fps: HashMap<usize, i32>,
    pub delay: Option<i32>,
    pub target_bitrate: Option<i32>,
    pub codec_format: Option<CodecFormat>,
    pub chroma: Option<String>,
    /// Average milliseconds a frame took to decode and convert.
    pub decode_ms: Option<f32>,
    /// Average milliseconds a frame took to hand to the UI.
    pub present_ms: Option<f32>,
}

#[inline]
pub fn new_voice_call_request(is_connect: bool) -> Message {
    let mut req = VoiceCallRequest::new();
    req.is_connect = is_connect;
    req.req_timestamp = get_time();
    let mut msg = Message::new();
    msg.set_voice_call_request(req);
    msg
}

#[inline]
pub fn new_voice_call_response(request_timestamp: i64, accepted: bool) -> Message {
    let mut resp = VoiceCallResponse::new();
    resp.accepted = accepted;
    resp.req_timestamp = request_timestamp;
    resp.ack_timestamp = get_time();
    let mut msg = Message::new();
    msg.set_voice_call_response(resp);
    msg
}

/// How fast the UI takes frames, going by how long it holds each one.
#[cfg(any(target_os = "ios", test))]
#[derive(Default, Clone)]
pub struct UiFrameMeter {
    taken: Option<std::time::Instant>,
    busy: std::time::Duration,
    longest: std::time::Duration,
    frames: u32,
}

#[cfg(any(target_os = "ios", test))]
impl UiFrameMeter {
    const MIN_FRAMES: u32 = 5;

    pub fn taken(&mut self) {
        self.taken = Some(std::time::Instant::now());
    }

    pub fn released(&mut self) {
        if let Some(taken) = self.taken.take() {
            self.add(taken.elapsed());
        }
    }

    fn add(&mut self, held: std::time::Duration) {
        self.busy += held;
        self.longest = self.longest.max(held);
        self.frames += 1;
    }

    /// The frames per second the UI could take since the last call, when it took enough to tell.
    pub fn take_fps(&mut self) -> Option<usize> {
        let meter = std::mem::take(self);
        self.taken = meter.taken;
        if meter.frames < Self::MIN_FRAMES {
            return None;
        }
        // One stall is not the pace.
        let micros = (meter.busy - meter.longest).as_micros();
        if micros == 0 {
            return None;
        }
        Some(((meter.frames - 1) as u128 * 1_000_000 / micros) as usize)
    }
}

/// Where a frame's time goes between its arrival and the UI, summed until taken.
#[cfg(any(target_os = "ios", test))]
#[derive(Default)]
pub struct FrameStages {
    decode_micros: std::sync::atomic::AtomicU64,
    present_micros: std::sync::atomic::AtomicU64,
    frames: std::sync::atomic::AtomicU64,
}

#[cfg(any(target_os = "ios", test))]
impl FrameStages {
    pub fn record(&self, decode: std::time::Duration, present: std::time::Duration) {
        use std::sync::atomic::Ordering::Relaxed;
        self.decode_micros.fetch_add(decode.as_micros() as _, Relaxed);
        self.present_micros.fetch_add(present.as_micros() as _, Relaxed);
        self.frames.fetch_add(1, Relaxed);
    }

    /// The average milliseconds of each stage since the last call, when there were frames.
    pub fn take(&self) -> Option<(f32, f32)> {
        use std::sync::atomic::Ordering::Relaxed;
        let frames = self.frames.swap(0, Relaxed);
        let decode = self.decode_micros.swap(0, Relaxed);
        let present = self.present_micros.swap(0, Relaxed);
        if frames == 0 {
            return None;
        }
        let ms = |micros: u64| micros as f32 / frames as f32 / 1000.;
        Some((ms(decode), ms(present)))
    }
}

/// What to do about a decoder that keeps failing.
#[cfg(any(target_os = "ios", test))]
#[derive(Debug, PartialEq)]
pub enum DecoderRecoveryStep {
    /// Start the decoder over and ask for a key frame.
    Restart,
    /// A restart is under way; the frames failing meanwhile say nothing.
    Wait,
    GiveUp,
}

/// A stream that starts over, as it does whenever the remote side restarts its encoder, can
/// fail the first frames of a decoder that is fine. Giving the codec up for that leaves the
/// rest of the session on software VP9, so the decoder gets a few fresh starts first.
#[cfg(any(target_os = "ios", test))]
#[derive(Default)]
pub struct DecoderRecovery {
    restarts: u32,
    waiting_until: Option<std::time::Instant>,
}

#[cfg(any(target_os = "ios", test))]
impl DecoderRecovery {
    const MAX_RESTARTS: u32 = 3;
    const KEY_FRAME_WAIT: std::time::Duration = std::time::Duration::from_secs(1);

    pub fn on_failure(&mut self, now: std::time::Instant) -> DecoderRecoveryStep {
        if self.waiting_until.is_some_and(|until| now < until) {
            return DecoderRecoveryStep::Wait;
        }
        if self.restarts >= Self::MAX_RESTARTS {
            return DecoderRecoveryStep::GiveUp;
        }
        self.restarts += 1;
        self.waiting_until = Some(now + Self::KEY_FRAME_WAIT);
        DecoderRecoveryStep::Restart
    }

    pub fn on_success(&mut self) {
        *self = Self::default();
    }
}

// The phone shows one video session at a time.
#[cfg(target_os = "ios")]
pub static FRAME_STAGES: FrameStages = FrameStages {
    decode_micros: std::sync::atomic::AtomicU64::new(0),
    present_micros: std::sync::atomic::AtomicU64::new(0),
    frames: std::sync::atomic::AtomicU64::new(0),
};

#[cfg(test)]
mod tests {
    use super::{DecoderRecovery, DecoderRecoveryStep, FrameStages, UiFrameMeter};
    use std::time::{Duration, Instant};

    #[test]
    fn a_failing_decoder_is_restarted_before_its_codec_is_given_up() {
        let mut recovery = DecoderRecovery::default();
        let start = Instant::now();
        let at = |ms: u64| start + Duration::from_millis(ms);
        assert_eq!(recovery.on_failure(at(0)), DecoderRecoveryStep::Restart);
        // The frames already on their way still fail.
        assert_eq!(recovery.on_failure(at(50)), DecoderRecoveryStep::Wait);
        recovery.on_success();
        // It never gets going again.
        assert_eq!(recovery.on_failure(at(5000)), DecoderRecoveryStep::Restart);
        assert_eq!(recovery.on_failure(at(6100)), DecoderRecoveryStep::Restart);
        assert_eq!(recovery.on_failure(at(7200)), DecoderRecoveryStep::Restart);
        assert_eq!(recovery.on_failure(at(7300)), DecoderRecoveryStep::Wait);
        assert_eq!(recovery.on_failure(at(8300)), DecoderRecoveryStep::GiveUp);
    }

    #[test]
    fn frame_stages_average_each_stage_since_the_last_reading() {
        let stages = FrameStages::default();
        assert_eq!(stages.take(), None);
        stages.record(Duration::from_millis(6), Duration::from_millis(1));
        stages.record(Duration::from_millis(10), Duration::from_millis(3));
        assert_eq!(stages.take(), Some((8., 2.)));
        assert_eq!(stages.take(), None);
    }

    #[test]
    fn ui_frame_meter_reports_the_pace_without_its_longest_frame() {
        let mut meter = UiFrameMeter::default();
        for _ in 0..4 {
            meter.add(Duration::from_millis(20));
        }
        assert_eq!(meter.take_fps(), None);
        for _ in 0..10 {
            meter.add(Duration::from_millis(20));
        }
        meter.add(Duration::from_millis(600));
        assert_eq!(meter.take_fps(), Some(50));
        assert_eq!(meter.take_fps(), None);
    }
}
