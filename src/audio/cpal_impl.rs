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
    Subscribe(CpalSubscriber),
    Unsubscribe(i32),
}

pub enum CpalResponse {
    SoundInputs(Vec<String>),
}

pub type CpalReqSender = mpsc::Sender<CpalRequest>;
pub type CpalReqReceiver = mpsc::Receiver<CpalRequest>;
pub type CpalRespSender = mpsc::Sender<CpalResponse>;
pub type CpalRespReceiver = mpsc::Receiver<CpalResponse>;

#[derive(Clone)]
pub struct CpalSubscriber {
    id: i32,
    tx: mpsc::Sender<Arc<Message>>,
}

impl CpalSubscriber {
    fn id(&self) -> i32 {
        self.id
    }

    fn send(&mut self, msg: Arc<Message>) {
        allow_err!(self.tx.send(msg));
    }
}

struct CpalService {
    host: Host,
    subscribers: Arc<Mutex<Vec<CpalSubscriber>>>,
    stream_config: Option<(Box<dyn StreamTrait>, Arc<Message>)>,
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
        subscribers: Arc::new(Mutex::new(Vec::new())),
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
            Ok(CpalRequest::Subscribe(s)) => {
                service.on_subscribe(s);
            }
            Ok(CpalRequest::Unsubscribe(id)) => {
                service.on_unsubscribe(id);
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
    fn on_subscribe(&mut self, sub: CpalSubscriber) {
        for s in self.subscribers.lock().unwrap().iter() {
            if s.id() == sub.id() {
                return;
            }
        }
        self.subscribers.lock().unwrap().push(sub.clone());
        self.start_sub(sub);
    }
    fn on_unsubscribe(&mut self, id: i32) {
        self.subscribers.lock().unwrap().retain(|s| s.id() != id);
    }

    fn ok(&self) -> bool {
        !self.subscribers.lock().unwrap().is_empty()
    }

    fn start_sub(&mut self, mut sub: CpalSubscriber) {
        match &self.stream_config {
            Some((_, msg)) => {
                sub.send(msg.clone());
            }
            None => {
                let subscribers = self.subscribers.clone();
                let cb = move |msg: Arc<Message>| {
                    for s in subscribers.lock().unwrap().iter_mut() {
                        s.send(msg.clone());
                    }
                };
                match cpal_play_cb(&self.host, cb) {
                    Ok((stream, msg)) => {
                        self.stream_config = Some((stream, msg.clone()));
                        sub.send(msg);
                    }
                    Err(e) => {
                        log::error!("Failed to play audio: {}", e);
                    }
                }
            }
        }
    }
}
