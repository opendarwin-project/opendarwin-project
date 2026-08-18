pub mod amlogic;
pub mod virtio_gpu_fb;

pub use amlogic::register_amlogic_fb;
pub use virtio_gpu_fb::register as register_virtio_gpu_fb;
