use cpal::{
    traits::{DeviceTrait, HostTrait, StreamTrait},
    BufferSize, Device, Host, InputCallbackInfo, StreamConfig, SupportedStreamConfig,
};
use hbb_common::{
    anyhow::anyhow,
    allow_err, bail, config::Config, log, message_proto::{Message, AudioFormat, Misc}, ResultType,
};
use lazy_static::lazy_static;
use magnum_opus::{Application::*, Channels::*, Encoder};
use std::{
    sync::{mpsc, Arc, Mutex},
    time::Duration,
};

#[cfg(feature = "audio_asio")]
lazy_static! {
    static ref CPAL_ASIO_TX_RX: Arc<Mutex<Option<(CpalSender, CpalReceiver)>>> =
        Arc::new(Mutex::new(try_start_cpal_asio()));
}

pub enum CpalRequest {
    SoundInputs,
    Close,
    // BuildInputStream {
    //     device: Device,
    //     config: StreamConfig,
    // },
}

pub enum CpalResponse {
    SoundInputs(Vec<String>),
  //  BuildInputStream(cpal::Stream),
}

pub type CpalSender = mpsc::Sender<CpalRequest>;
pub type CpalReceiver = mpsc::Receiver<CpalResponse>;

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
fn try_start_cpal_asio() -> Option<(CpalSender, CpalReceiver)> {
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
    std::thread::spawn(move || loop {
        match req_rx.recv() {
            Ok(CpalRequest::SoundInputs) => {
                allow_err!(rsep_tx.send(CpalResponse::SoundInputs(get_sound_inputs_(&host))));
            }
            Ok(CpalRequest::Close) => {
                break;
            }
            Err(e) => {
                log::error!("Failed to receive data: {}", e);
                break;
            }
        }
    });
    Some((req_tx, resp_rx))
}

// #[cfg(windows)]
// fn get_device(host: &Host) -> ResultType<(Device, SupportedStreamConfig)> {
//     let audio_input = Config::get_option("audio-input");
//     if !audio_input.is_empty() {
//         return get_audio_input(host, &audio_input);
//     }
//     let device = host
//         .default_output_device()
//         .with_context(|| "Failed to get default output device for loopback")?;
//     log::info!(
//         "Default output device: {}",
//         device.name().unwrap_or("".to_owned())
//     );
//     let format = device
//         .default_output_config()
//         .map_err(|e| anyhow!(e))
//         .with_context(|| "Failed to get default output format")?;
//     log::info!("Default output format: {:?}", format);
//     Ok((device, format))
// }

// #[cfg(not(windows))]
// fn get_device(host: &Host) -> ResultType<(Device, SupportedStreamConfig)> {
//     let audio_input = Config::get_option("audio-input");
//     get_audio_input(host, &audio_input)
// }

// fn get_audio_input(host: &Host, audio_input: &str) -> ResultType<(Device, SupportedStreamConfig)> {
//     let mut device = None;
//     if !audio_input.is_empty() {
//         for d in host
//             .devices()
//             .with_context(|| "Failed to get audio devices")?
//         {
//             if d.name().unwrap_or("".to_owned()) == audio_input {
//                 device = Some(d);
//                 break;
//             }
//         }
//     }
//     let device = device.unwrap_or(
//         host.default_input_device()
//             .with_context(|| "Failed to get default input device for loopback")?,
//     );
//     log::info!("Input device: {}", device.name().unwrap_or("".to_owned()));
//     let format = device
//         .default_input_config()
//         .map_err(|e| anyhow!(e))
//         .with_context(|| "Failed to get default input format")?;
//     log::info!("Default input format: {:?}", format);
//     Ok((device, format))
// }

// fn play(host: &Host, sp: GenericService) -> ResultType<(Box<dyn StreamTrait>, Arc<Message>)>
// {
//     use cpal::SampleFormat::*;
//     let (device, config) = get_device(host)?;
//     // Sample rate must be one of 8000, 12000, 16000, 24000, or 48000.
//     let sample_rate_0 = config.sample_rate().0;
//     let sample_rate = if sample_rate_0 < 12000 {
//         8000
//     } else if sample_rate_0 < 16000 {
//         12000
//     } else if sample_rate_0 < 24000 {
//         16000
//     } else if sample_rate_0 < 48000 {
//         24000
//     } else {
//         48000
//     };
//     let ch = if config.channels() > 1 { Stereo } else { Mono };
//     let stream = match config.sample_format() {
//         I8 => build_input_stream::<i8>(device, &config, sp, sample_rate, ch)?,
//         I16 => build_input_stream::<i16>(device, &config, sp, sample_rate, ch)?,
//         I32 => build_input_stream::<i32>(device, &config, sp, sample_rate, ch)?,
//         I64 => build_input_stream::<i64>(device, &config, sp, sample_rate, ch)?,
//         U8 => build_input_stream::<u8>(device, &config, sp, sample_rate, ch)?,
//         U16 => build_input_stream::<u16>(device, &config, sp, sample_rate, ch)?,
//         U32 => build_input_stream::<u32>(device, &config, sp, sample_rate, ch)?,
//         U64 => build_input_stream::<u64>(device, &config, sp, sample_rate, ch)?,
//         F32 => build_input_stream::<f32>(device, &config, sp, sample_rate, ch)?,
//         F64 => build_input_stream::<f64>(device, &config, sp, sample_rate, ch)?,
//         f => bail!("unsupported audio format: {:?}", f),
//     };
//     stream.play()?;
//     Ok((
//         Box::new(stream),
//         Arc::new(create_format_msg(sample_rate, ch as _)),
//     ))
// }

// fn create_format_msg(sample_rate: u32, channels: u16) -> Message {
//     let format = AudioFormat {
//         sample_rate,
//         channels: channels as _,
//         ..Default::default()
//     };
//     let mut misc = Misc::new();
//     misc.set_audio_format(format);
//     let mut msg = Message::new();
//     msg.set_misc(misc);
//     msg
// }

// fn build_input_stream<T>(
//     device: cpal::Device,
//     config: &cpal::SupportedStreamConfig,
//     sp: GenericService,
//     sample_rate: u32,
//     encode_channel: magnum_opus::Channels,
// ) -> ResultType<cpal::Stream>
// where
//     T: cpal::SizedSample + dasp::sample::ToSample<f32>
// {
//     let err_fn = move |err| {
//         // too many UnknownErrno, will improve later
//         log::trace!("an error occurred on stream: {}", err);
//     };
//     let sample_rate_0 = config.sample_rate().0;
//     log::debug!("Audio sample rate : {}", sample_rate);
//     let device_channel = config.channels();
//     let mut encoder = Encoder::new(sample_rate, encode_channel, LowDelay)?;
//     // https://www.opus-codec.org/docs/html_api/group__opusencoder.html#gace941e4ef26ed844879fde342ffbe546
//     // https://chromium.googlesource.com/chromium/deps/opus/+/1.1.1/include/opus.h
//     let frame_size = sample_rate as usize / 100; // 10 ms
//     let encode_len = frame_size * encode_channel as usize;
//     let rechannel_len = encode_len * device_channel as usize / encode_channel as usize;
//     let timeout = None;
//     let stream_config = StreamConfig {
//         channels: device_channel,
//         sample_rate: config.sample_rate(),
//         buffer_size: BufferSize::Default,
//     };
//     let stream = device.build_input_stream(&stream_config, data_callback, err_fn, timeout)?;
//     Ok(stream)
// }
