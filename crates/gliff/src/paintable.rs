//! A paintable that shows a frame at a whole number of device pixels per
//! stream pixel.
//!
//! The server declares a full-quality `view` size in device pixels. When
//! the widget has room, the frame is drawn at the largest integer factor
//! that fits (1x, 2x, ...) and centred. The decoder is asked to write its
//! output at that same factor (pixel replication in the recombine shader,
//! or on the CPU), so the texture GTK receives is already device sized and
//! is drawn 1:1 with a plain texture node, which stays pixel-exact. GTK's
//! own nearest-neighbour scaling is not used: on a HiDPI surface its
//! renderer draws a scaled texture through an offscreen at logical
//! resolution, which blurs the result. When the widget is smaller than the
//! view, the frame shrinks to fit with linear filtering. A stream sent at
//! reduced resolution (view larger than the texture) is stretched to the
//! view box either way, so a quality change never moves the picture.
//!
//! [`layout`] is the single source of the frame's rectangle; the pointer
//! mapping and the zoom request in `main.rs` derive from it.

use std::cell::{Cell, RefCell};

use gtk::gdk;
use gtk::glib;
use gtk::graphene;
use gtk::prelude::*;
use gtk::subclass::prelude::*;
use gtk4 as gtk;

/// Where the frame is drawn inside the widget, in logical pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Layout {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    /// Device pixels per view pixel; a whole number when the view fits.
    pub factor: f64,
}

impl Layout {
    /// The integer zoom to ask of the decoder: the factor when the view
    /// fits, else 1 (a shrunk frame is resampled anyway).
    pub fn zoom(&self) -> u32 {
        if self.factor >= 1.0 {
            self.factor as u32
        } else {
            1
        }
    }
}

/// Fit a `view` (device pixels) into a widget of `width` x `height` logical
/// pixels on a display of `device` scale: the largest integer factor that
/// fits, else a fractional shrink. Offsets are snapped to device pixels so
/// an integer factor stays pixel-aligned.
pub fn layout(view: (u32, u32), device: i32, width: f64, height: f64) -> Option<Layout> {
    let (vw, vh) = (view.0 as f64, view.1 as f64);
    if vw <= 0.0 || vh <= 0.0 || width <= 0.0 || height <= 0.0 {
        return None;
    }
    let device = device.max(1) as f64;
    let fit = (width * device / vw).min(height * device / vh);
    let factor = if fit >= 1.0 { fit.floor() } else { fit };
    let (fw, fh) = (vw * factor / device, vh * factor / device);
    let snap = |v: f64| (v * device).floor() / device;
    Some(Layout {
        x: snap((width - fw) / 2.0),
        y: snap((height - fh) / 2.0),
        width: fw,
        height: fh,
        factor,
    })
}

/// The zoom steps of pan view, in device pixels per view pixel.
pub const PAN_ZOOMS: [f64; 5] = [1.0, 1.25, 1.5, 2.0, 3.0];

/// The next pan zoom after `current` in direction `dir` (+1 in, -1 out),
/// stopping at the ends of [`PAN_ZOOMS`].
pub fn step_pan_zoom(current: f64, dir: i32) -> f64 {
    let at = PAN_ZOOMS
        .iter()
        .position(|z| (z - current).abs() < 1e-6)
        .unwrap_or(0) as i32;
    PAN_ZOOMS[(at + dir).clamp(0, PAN_ZOOMS.len() as i32 - 1) as usize]
}

/// Pan view: draw the frame at `zoom` device pixels per view pixel, larger
/// than the widget, and slide it so the point under the pointer stays under
/// the pointer. The pointer's place across the widget is its place across
/// the frame, so the left edge shows the frame's left edge and the right edge
/// its right edge, and moving the pointer scrolls the whole picture past it.
/// An axis the frame does not fill is centred. `px`/`py` are the pointer in
/// logical widget pixels.
#[allow(clippy::too_many_arguments)]
pub fn pan_layout(
    view: (u32, u32),
    device: i32,
    width: f64,
    height: f64,
    zoom: f64,
    px: f64,
    py: f64,
) -> Option<Layout> {
    let (vw, vh) = (view.0 as f64, view.1 as f64);
    if vw <= 0.0 || vh <= 0.0 || width <= 0.0 || height <= 0.0 || zoom <= 0.0 {
        return None;
    }
    let device = device.max(1) as f64;
    let (fw, fh) = (vw * zoom / device, vh * zoom / device);
    let snap = |v: f64| (v * device).floor() / device;
    let place = |frame: f64, room: f64, pointer: f64| {
        if frame <= room {
            snap((room - frame) / 2.0)
        } else {
            snap(-(pointer / room).clamp(0.0, 1.0) * (frame - room))
        }
    };
    Some(Layout {
        x: place(fw, width, px),
        y: place(fh, height, py),
        width: fw,
        height: fh,
        factor: zoom,
    })
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct FramePaintable {
        pub texture: RefCell<Option<gdk::Texture>>,
        pub scale: Cell<i32>,
        /// The full-quality fit size in device pixels; the texture is
        /// stretched to it when the stream is scaled down.
        pub view: Cell<(u32, u32)>,
        /// Pan view zoom, or None to fit the whole frame in the widget.
        pub pan: Cell<Option<f64>>,
        /// The pointer in logical widget pixels, which positions a panned
        /// frame.
        pub pointer: Cell<(f64, f64)>,
    }

    impl FramePaintable {
        fn view_or_texture(&self) -> (i32, i32) {
            let (vw, vh) = self.view.get();
            if vw > 0 && vh > 0 {
                return (vw as i32, vh as i32);
            }
            self.texture
                .borrow()
                .as_ref()
                .map_or((0, 0), |t| (t.width(), t.height()))
        }
    }

    #[glib::object_subclass]
    impl ObjectSubclass for FramePaintable {
        const NAME: &'static str = "GliffFramePaintable";
        type Type = super::FramePaintable;
        type Interfaces = (gdk::Paintable,);
    }

    impl ObjectImpl for FramePaintable {}

    impl PaintableImpl for FramePaintable {
        fn intrinsic_width(&self) -> i32 {
            self.view_or_texture().0 / self.scale.get().max(1)
        }

        fn intrinsic_height(&self) -> i32 {
            self.view_or_texture().1 / self.scale.get().max(1)
        }

        fn intrinsic_aspect_ratio(&self) -> f64 {
            let (w, h) = self.view_or_texture();
            if h == 0 {
                return 0.0;
            }
            w as f64 / h as f64
        }

        fn snapshot(&self, snapshot: &gdk::Snapshot, width: f64, height: f64) {
            let Some(t) = self.texture.borrow().clone() else {
                return;
            };
            let (vw, vh) = self.view_or_texture();
            let view = (vw as u32, vh as u32);
            let l = match self.pan.get() {
                Some(zoom) => {
                    let (px, py) = self.pointer.get();
                    pan_layout(view, self.scale.get(), width, height, zoom, px, py)
                }
                None => layout(view, self.scale.get(), width, height),
            };
            let Some(l) = l else {
                return;
            };
            let bounds =
                graphene::Rect::new(l.x as f32, l.y as f32, l.width as f32, l.height as f32);
            if self.pan.get().is_some() {
                // The frame overhangs the widget; keep it inside.
                snapshot.push_clip(&graphene::Rect::new(0.0, 0.0, width as f32, height as f32));
                snapshot.append_texture(&t, &bounds);
                snapshot.pop();
                return;
            }
            snapshot.append_texture(&t, &bounds);
        }
    }
}

glib::wrapper! {
    pub struct FramePaintable(ObjectSubclass<imp::FramePaintable>) @implements gdk::Paintable;
}

impl Default for FramePaintable {
    fn default() -> Self {
        let p: Self = glib::Object::new();
        p.imp().scale.set(1);
        p
    }
}

impl FramePaintable {
    /// Show `texture` inside a `view`-sized area (device pixels) on a
    /// display of `scale_factor`.
    pub fn set_frame(&self, texture: gdk::Texture, scale_factor: i32, view: (u32, u32)) {
        let imp = self.imp();
        let size_changed = imp.scale.get() != scale_factor || imp.view.get() != view;
        imp.scale.set(scale_factor);
        imp.view.set(view);
        *imp.texture.borrow_mut() = Some(texture);
        if size_changed {
            self.invalidate_size();
        }
        self.invalidate_contents();
    }

    /// Follow a display scale change without waiting for a new frame, so
    /// the drawn rectangle and the pointer mapping agree.
    pub fn set_scale(&self, scale_factor: i32) {
        let imp = self.imp();
        if imp.scale.get() != scale_factor {
            imp.scale.set(scale_factor);
            self.invalidate_size();
            self.invalidate_contents();
        }
    }

    /// Turn pan view on at `zoom`, or off (None) to fit the whole frame.
    pub fn set_pan(&self, zoom: Option<f64>) {
        let imp = self.imp();
        if imp.pan.get() != zoom {
            imp.pan.set(zoom);
            self.invalidate_contents();
        }
    }

    /// The pan zoom, or None while the whole frame is fitted.
    pub fn pan(&self) -> Option<f64> {
        self.imp().pan.get()
    }

    /// Follow the pointer, in logical widget pixels. Only a panned frame
    /// moves with it.
    pub fn set_pointer(&self, x: f64, y: f64) {
        let imp = self.imp();
        if imp.pointer.get() != (x, y) {
            imp.pointer.set((x, y));
            if imp.pan.get().is_some() {
                self.invalidate_contents();
            }
        }
    }

    /// Show nothing, as when no machine is connected.
    pub fn clear(&self) {
        let imp = self.imp();
        imp.view.set((0, 0));
        if imp.texture.borrow_mut().take().is_some() {
            self.invalidate_size();
            self.invalidate_contents();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doubles_when_the_widget_has_room() {
        let l = layout((2560, 1440), 2, 2560.0, 1440.0).unwrap();
        assert_eq!(l.factor, 2.0);
        assert_eq!((l.x, l.y, l.width, l.height), (0.0, 0.0, 2560.0, 1440.0));
    }

    #[test]
    fn drops_to_one_when_two_does_not_fit() {
        let l = layout((2560, 1440), 2, 2560.0, 1400.0).unwrap();
        assert_eq!(l.factor, 1.0);
        assert_eq!((l.width, l.height), (1280.0, 720.0));
        assert_eq!((l.x, l.y), (640.0, 340.0));
    }

    #[test]
    fn shrinks_fractionally_when_too_small() {
        let l = layout((2560, 1440), 1, 1280.0, 1000.0).unwrap();
        assert_eq!(l.factor, 0.5);
        assert_eq!((l.width, l.height), (1280.0, 720.0));
        assert_eq!((l.x, l.y), (0.0, 140.0));
    }

    #[test]
    fn offsets_snap_to_device_pixels() {
        let l = layout((1001, 601), 2, 1000.0, 600.0).unwrap();
        assert_eq!(l.factor, 1.0);
        assert_eq!(l.x * 2.0, (l.x * 2.0).floor());
        assert_eq!(l.y * 2.0, (l.y * 2.0).floor());
    }

    #[test]
    fn zoom_is_the_integer_factor_or_one() {
        assert_eq!(layout((2560, 1440), 2, 2560.0, 1440.0).unwrap().zoom(), 2);
        assert_eq!(layout((2560, 1440), 2, 2560.0, 1400.0).unwrap().zoom(), 1);
        assert_eq!(layout((2560, 1440), 1, 1280.0, 1000.0).unwrap().zoom(), 1);
    }

    #[test]
    fn empty_inputs_have_no_layout() {
        assert!(layout((0, 0), 2, 100.0, 100.0).is_none());
        assert!(layout((10, 10), 2, 0.0, 100.0).is_none());
    }

    // A 4096x1728 stream on a 1920x1080 widget at 1x.
    const V: (u32, u32) = (4096, 1728);

    #[test]
    fn pan_left_edge_shows_the_frame_left_edge() {
        let l = pan_layout(V, 1, 1920.0, 1080.0, 1.0, 0.0, 0.0).unwrap();
        assert_eq!((l.x, l.y), (0.0, 0.0));
        assert_eq!((l.width, l.height), (4096.0, 1728.0));
    }

    #[test]
    fn pan_right_edge_shows_the_frame_right_edge() {
        let l = pan_layout(V, 1, 1920.0, 1080.0, 1.0, 1920.0, 1080.0).unwrap();
        assert_eq!((l.x, l.y), (-(4096.0 - 1920.0), -(1728.0 - 1080.0)));
    }

    #[test]
    fn pan_keeps_the_point_under_the_pointer_under_the_pointer() {
        // Whatever the pointer position, the frame pixel under it is
        // pointer / widget across the frame, so the cursor and the thing it
        // points at never drift apart.
        for px in [0.0, 1.0, 480.0, 960.0, 1500.0, 1920.0] {
            let l = pan_layout(V, 1, 1920.0, 1080.0, 1.0, px, 0.0).unwrap();
            let frame_x = px - l.x;
            let want = px / 1920.0 * 4096.0;
            assert!((frame_x - want).abs() < 1.0, "px {px}: {frame_x} vs {want}");
        }
    }

    #[test]
    fn pan_centres_an_axis_the_frame_does_not_fill() {
        let l = pan_layout((800, 400), 1, 1920.0, 1080.0, 1.0, 5.0, 5.0).unwrap();
        assert_eq!((l.x, l.y), (560.0, 340.0));
    }

    #[test]
    fn pan_clamps_a_pointer_outside_the_widget() {
        let a = pan_layout(V, 1, 1920.0, 1080.0, 1.0, -50.0, -50.0).unwrap();
        let b = pan_layout(V, 1, 1920.0, 1080.0, 1.0, 0.0, 0.0).unwrap();
        assert_eq!(a, b);
        let c = pan_layout(V, 1, 1920.0, 1080.0, 1.0, 9999.0, 9999.0).unwrap();
        let d = pan_layout(V, 1, 1920.0, 1080.0, 1.0, 1920.0, 1080.0).unwrap();
        assert_eq!(c, d);
    }

    #[test]
    fn pan_zoom_scales_the_frame_and_the_offset_range() {
        let l = pan_layout(V, 1, 1920.0, 1080.0, 2.0, 1920.0, 0.0).unwrap();
        assert_eq!((l.width, l.height), (8192.0, 3456.0));
        assert_eq!(l.x, -(8192.0 - 1920.0));
    }

    #[test]
    fn pan_offsets_snap_to_device_pixels() {
        let l = pan_layout(V, 2, 1000.0, 600.0, 1.0, 333.3, 111.1).unwrap();
        assert_eq!(l.x * 2.0, (l.x * 2.0).floor());
        assert_eq!(l.y * 2.0, (l.y * 2.0).floor());
    }

    #[test]
    fn pan_has_no_layout_for_empty_inputs() {
        assert!(pan_layout((0, 0), 1, 100.0, 100.0, 1.0, 0.0, 0.0).is_none());
        assert!(pan_layout(V, 1, 100.0, 100.0, 0.0, 0.0, 0.0).is_none());
    }

    #[test]
    fn zoom_steps_stop_at_the_ends() {
        assert_eq!(step_pan_zoom(1.0, -1), 1.0);
        assert_eq!(step_pan_zoom(1.0, 1), 1.25);
        assert_eq!(step_pan_zoom(2.0, 1), 3.0);
        assert_eq!(step_pan_zoom(3.0, 1), 3.0);
        assert_eq!(step_pan_zoom(1.7, 1), 1.25);
    }
}
