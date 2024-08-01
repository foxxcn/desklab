use crate::server::audio_service::cpal_play_cb;
use cpal::{
    traits::{DeviceTrait, HostTrait, StreamTrait},
    Host,
};
use hbb_common::{allow_err, log, message_proto::Message, ResultType};
use lazy_static::lazy_static;
use std::{
    sync::{mpsc, Arc, Mutex},
    time::Duration,
};

#[cfg(feature = "audio_asio")]
lazy_static! {
    static ref CPAL_ASIO_TX_RX: Arc<Mutex<Option<(CpalReqSender, CpalRespReceiver)>>> =
        Arc::new(Mutex::new(try_start_cpal_asio()));
    static ref INPUT_BUFFER: Arc<Mutex<std::collections::VecDeque<f32>>> = Default::default();
}

pub enum CpalRequest {
    SoundInputs,
    Close,
    Start(mpsc::Sender<AudioData>),
    Stop,
}

pub enum CpalResponse {
    SoundInputs(Vec<String>),
}

pub type CpalReqSender = mpsc::Sender<CpalRequest>;
pub type CpalReqReceiver = mpsc::Receiver<CpalRequest>;
pub type CpalRespSender = mpsc::Sender<CpalResponse>;
pub type CpalRespReceiver = mpsc::Receiver<CpalResponse>;

pub enum AudioData {
    Format(Arc<Message>),
    Data(Arc<Message>),
}

struct CpalService {
    host: Host,
    stream_config: Option<(Box<dyn StreamTrait>, Arc<Message>)>,
}

#[cfg(feature = "audio_asio")]
pub fn start(tx_msg: mpsc::Sender<AudioData>) {
    if let Some((tx, _)) = &*CPAL_ASIO_TX_RX.lock().unwrap() {
        allow_err!(tx.send(CpalRequest::Start(tx_msg)));
    }
}

#[cfg(feature = "audio_asio")]
pub fn stop() {
    if let Some((tx, _)) = &*CPAL_ASIO_TX_RX.lock().unwrap() {
        allow_err!(tx.send(CpalRequest::Stop));
    }
}

pub fn get_sound_inputs(timeout: Duration) -> ResultType<Vec<String>> {
    #[cfg(feature = "audio_asio")]
    let cpal_tx_rx = CPAL_ASIO_TX_RX.lock().unwrap();
    #[cfg(feature = "audio_asio")]
    if let Some((tx, rx)) = &*cpal_tx_rx {
        tx.send(CpalRequest::SoundInputs)?;
        return match rx.recv_timeout(timeout) {
            Ok(CpalResponse::SoundInputs(inputs)) => Ok(inputs),
            Err(e) => {
                log::error!("Failed to get sound inputs: {}", e);
                Err(e.into())
            }
        };
    }

    let host = cpal::default_host();
    Ok(get_sound_inputs_(&host))
}

fn get_sound_inputs_(host: &Host) -> Vec<String> {
    let mut out = Vec::new();
    if let Ok(devices) = host.devices() {
        for device in devices {
            if device.default_input_config().is_err() {
                continue;
            }
            if let Ok(name) = device.name() {
                out.push(name);
            }
        }
    }
    out
}

#[cfg(feature = "audio_asio")]
fn try_start_cpal_asio() -> Option<(CpalReqSender, CpalRespReceiver)> {
    let host = match cpal::host_from_id(cpal::HostId::Asio) {
        Ok(host) => {
            log::info!("Using Asio host");
            host
        }
        Err(e) => {
            log::error!("Failed to get Asio host: {}", e);
            return None;
        }
    };
    let (req_tx, req_rx) = mpsc::channel();
    let (rsep_tx, resp_rx) = mpsc::channel();
    std::thread::spawn(move || cpal_thread_loop(host, req_rx, rsep_tx));
    Some((req_tx, resp_rx))
}

#[cfg(feature = "audio_asio")]
fn cpal_thread_loop(host: Host, req_rx: CpalReqReceiver, rsep_tx: CpalRespSender) {
    use std::sync::mpsc::RecvTimeoutError;

    log::info!("Cpal thread loop start.");

    let mut service = CpalService {
        host,
        stream_config: None,
    };
    let recv_timeout = Duration::from_millis(300);
    loop {
        match req_rx.recv_timeout(recv_timeout) {
            Ok(CpalRequest::SoundInputs) => {
                allow_err!(
                    rsep_tx.send(CpalResponse::SoundInputs(get_sound_inputs_(&service.host)))
                );
            }
            Ok(CpalRequest::Close) => {
                log::info!("Cpal thread loop close.");
                break;
            }
            Ok(CpalRequest::Start(s)) => {
                service.start(s);
            }
            Ok(CpalRequest::Stop) => {
                service.stop();
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => {
                log::error!("Cpal msg channel is disconnected, thread loop eixt.");
                break;
            }
        }
    }
    log::info!("Cpal thread loop exit.");
}

impl CpalService {
    fn start(&mut self, tx: mpsc::Sender<AudioData>) {
        match &self.stream_config {
            Some((_, msg)) => {
                // unreachable!();
                // We only consider one subscriber for now.
                // This can easily be changed to multiple subscribers if needed.
                allow_err!(tx.send(AudioData::Format(msg.clone())));
            }
            None => {
                let tx_cloned = tx.clone();
                let cb = move |msg: Arc<Message>| {
                    allow_err!(tx_cloned.send(AudioData::Data(msg.clone())));
                };
                match cpal_play_cb(&self.host, cb) {
                    Ok((stream, msg)) => {
                        self.stream_config = Some((stream, msg.clone()));
                        allow_err!(tx.send(AudioData::Format(msg)));
                    }
                    Err(e) => {
                        log::error!("Failed to play audio: {}", e);
                    }
                }
            }
        }
    }

    fn stop(&mut self) {
        let _ = self.stream_config.take();
    }
}
