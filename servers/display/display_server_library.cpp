/**************************************************************************/
/*  display_server_library.cpp                                            */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "display_server_library.h"

#include "servers/display/native_menu.h"

Ref<RenderingNativeSurface> DisplayServerLibrary::pending_main_surface;

DisplayServerLibrary *DisplayServerLibrary::get_singleton() {
	return Object::cast_to<DisplayServerLibrary>(DisplayServer::get_singleton());
}

void DisplayServerLibrary::set_native_surface(Ref<RenderingNativeSurface> p_native_surface) {
	ERR_FAIL_COND_MSG(DisplayServer::get_singleton() != nullptr, "The display server has already started. Give additional surfaces to a Window with Window.set_native_surface().");
	pending_main_surface = p_native_surface;
}

void DisplayServerLibrary::_bind_methods() {
	ClassDB::bind_static_method("DisplayServerLibrary", D_METHOD("set_native_surface", "native_surface"), &DisplayServerLibrary::set_native_surface);
	ClassDB::bind_method(D_METHOD("resize_window", "size", "id"), &DisplayServerLibrary::resize_window);
	ClassDB::bind_method(D_METHOD("touch_press", "idx", "x", "y", "pressed", "double_click", "window"), &DisplayServerLibrary::touch_press);
	ClassDB::bind_method(D_METHOD("touch_drag", "idx", "prev_x", "prev_y", "x", "y", "pressure", "tilt", "window"), &DisplayServerLibrary::touch_drag);
	ClassDB::bind_method(D_METHOD("touches_canceled", "idx", "window"), &DisplayServerLibrary::touches_canceled);
	ClassDB::bind_method(D_METHOD("key", "key", "char", "unshifted", "physical", "modifiers", "pressed", "window"), &DisplayServerLibrary::key, DEFVAL(DisplayServerEnums::MAIN_WINDOW_ID));
}

DisplayServerLibrary::DisplayServerLibrary(const String &p_rendering_driver, DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::VSyncMode p_vsync_mode, uint32_t p_flags, const Vector2i *p_position, const Vector2i &p_resolution, int p_screen, DisplayServerEnums::Context p_context, Error &r_error) {
	r_error = ERR_UNAVAILABLE;
	rendering_driver = p_rendering_driver;
	native_menu = memnew(NativeMenu);

	Ref<RenderingNativeSurface> main_surface = pending_main_surface;
	pending_main_surface.unref();
	ERR_FAIL_COND_MSG(main_surface.is_null(), "Call DisplayServerLibrary.set_native_surface() before starting the Godot instance.");

	if (_initialize_rendering(main_surface) != OK) {
		return;
	}

	Input::get_singleton()->set_event_dispatch_function(_dispatch_input_events);
	r_error = OK;
}

DisplayServerLibrary::~DisplayServerLibrary() {
	for (const KeyValue<DisplayServerEnums::WindowID, NativeWindow> &entry : windows) {
		_destroy_rendering_surface(entry.key);
	}

#if defined(RD_ENABLED)
	if (rendering_device) {
		memdelete(rendering_device);
		rendering_device = nullptr;
	}
	if (rendering_context) {
		memdelete(rendering_context);
		rendering_context = nullptr;
	}
#endif

	windows.clear();

	if (native_menu) {
		memdelete(native_menu);
		native_menu = nullptr;
	}
}

Error DisplayServerLibrary::_initialize_rendering(const Ref<RenderingNativeSurface> &p_main_surface) {
#if defined(RD_ENABLED)
	rendering_context = p_main_surface->create_rendering_context(rendering_driver);
	ERR_FAIL_NULL_V_MSG(rendering_context, ERR_UNAVAILABLE, vformat("The native surface cannot create a \"%s\" rendering context.", rendering_driver));
	ERR_FAIL_COND_V_MSG(rendering_context->initialize() != OK, ERR_UNAVAILABLE, vformat("Could not initialize the %s rendering context.", rendering_driver));

	ERR_FAIL_COND_V_MSG(create_native_window(p_main_surface, DisplayServerEnums::WINDOW_MODE_FULLSCREEN, 0) != DisplayServerEnums::MAIN_WINDOW_ID, ERR_UNAVAILABLE, "Could not create the main window.");
	rendering_device = memnew(RenderingDevice);
	if (rendering_device->initialize(rendering_context, DisplayServerEnums::MAIN_WINDOW_ID) != OK) {
		memdelete(rendering_device);
		rendering_device = nullptr;
		ERR_FAIL_V_MSG(ERR_UNAVAILABLE, "Could not initialize the rendering device.");
	}
	ERR_FAIL_COND_V_MSG(rendering_device->screen_create(DisplayServerEnums::MAIN_WINDOW_ID) != OK, ERR_UNAVAILABLE, "Could not create the main window's swapchain.");

	RendererCompositorRD::make_current();
	return OK;
#else
	ERR_FAIL_V_MSG(ERR_UNAVAILABLE, "The library display server requires a RenderingDevice driver such as Metal.");
#endif
}

Error DisplayServerLibrary::_create_rendering_surface(DisplayServerEnums::WindowID p_window, const Ref<RenderingNativeSurface> &p_surface) {
#if defined(RD_ENABLED)
	ERR_FAIL_NULL_V(rendering_context, ERR_UNCONFIGURED);

	Error err = rendering_context->window_create(p_window, p_surface);
	ERR_FAIL_COND_V_MSG(err != OK, err, vformat("Could not create a %s surface for window %d.", rendering_driver, p_window));

	if (p_surface->has_host_pixel_size()) {
		_resize_rendering_surface(p_window, p_surface->get_host_pixel_size());
	}

	if (rendering_device == nullptr) {
		return OK;
	}

	err = rendering_device->screen_create(p_window);
	if (err != OK) {
		rendering_context->window_destroy(p_window);
	}
	return err;
#else
	return ERR_UNAVAILABLE;
#endif
}

void DisplayServerLibrary::_destroy_rendering_surface(DisplayServerEnums::WindowID p_window) {
#if defined(RD_ENABLED)
	if (rendering_device) {
		rendering_device->screen_free(p_window);
	}
	if (rendering_context) {
		rendering_context->window_destroy(p_window);
	}
#endif
}

DisplayServerLibrary::NativeWindow *DisplayServerLibrary::_get_window(DisplayServerEnums::WindowID p_window) {
	return windows.getptr(p_window);
}

const DisplayServerLibrary::NativeWindow *DisplayServerLibrary::_get_window(DisplayServerEnums::WindowID p_window) const {
	return windows.getptr(p_window);
}

DisplayServer *DisplayServerLibrary::create_func(const String &p_rendering_driver, DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::VSyncMode p_vsync_mode, uint32_t p_flags, const Vector2i *p_position, const Vector2i &p_resolution, int p_screen, DisplayServerEnums::Context p_context, int64_t p_parent_window, Error &r_error) {
	return memnew(DisplayServerLibrary(p_rendering_driver, p_mode, p_vsync_mode, p_flags, p_position, p_resolution, p_screen, p_context, r_error));
}

Vector<String> DisplayServerLibrary::get_rendering_drivers_func() {
	Vector<String> drivers;
#if defined(METAL_ENABLED)
	drivers.push_back("metal");
#endif
	return drivers;
}

void DisplayServerLibrary::register_library_driver() {
	register_create_function("library", create_func, get_rendering_drivers_func);
}

DisplayServerEnums::WindowID DisplayServerLibrary::create_native_window(const Ref<RenderingNativeSurface> &p_native_surface, DisplayServerEnums::WindowMode p_mode, uint32_t p_flags) {
	ERR_FAIL_COND_V(p_native_surface.is_null(), DisplayServerEnums::INVALID_WINDOW_ID);

	DisplayServerEnums::WindowID window_id = next_window_id;
	ERR_FAIL_COND_V(_create_rendering_surface(window_id, p_native_surface) != OK, DisplayServerEnums::INVALID_WINDOW_ID);

	next_window_id++;
	NativeWindow &window = windows[window_id];
	window.surface = p_native_surface;
	window.mode = p_mode;
	window.flags = p_flags;
	return window_id;
}

void DisplayServerLibrary::show_window(DisplayServerEnums::WindowID p_window) {
}

void DisplayServerLibrary::delete_sub_window(DisplayServerEnums::WindowID p_window) {
	ERR_FAIL_COND_MSG(p_window == DisplayServerEnums::MAIN_WINDOW_ID, "The main window's surface belongs to the embedding application and lives as long as the display server.");
	ERR_FAIL_COND(!windows.has(p_window));

	_destroy_rendering_surface(p_window);
	windows.erase(p_window);
}

void DisplayServerLibrary::window_set_mouse_passthrough(const Vector<Vector2> &p_region, DisplayServerEnums::WindowID p_window) {
}

void DisplayServerLibrary::window_set_rect_changed_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
	NativeWindow *window = _get_window(p_window);
	ERR_FAIL_NULL(window);
	window->rect_changed_callback = p_callable;
}

void DisplayServerLibrary::window_set_window_event_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
	NativeWindow *window = _get_window(p_window);
	ERR_FAIL_NULL(window);
	window->window_event_callback = p_callable;
}

void DisplayServerLibrary::window_set_input_event_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
	NativeWindow *window = _get_window(p_window);
	ERR_FAIL_NULL(window);
	window->input_event_callback = p_callable;
}

void DisplayServerLibrary::window_set_input_text_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
	NativeWindow *window = _get_window(p_window);
	ERR_FAIL_NULL(window);
	window->input_text_callback = p_callable;
}

void DisplayServerLibrary::window_set_drop_files_callback(const Callable &p_callable, DisplayServerEnums::WindowID p_window) {
}

void DisplayServerLibrary::process_events() {
	Input::get_singleton()->flush_buffered_events();
}

void DisplayServerLibrary::_dispatch_input_events(const Ref<InputEvent> &p_event) {
	Ref<InputEventFromWindow> event_from_window = p_event;
	DisplayServerEnums::WindowID window_id = DisplayServerEnums::INVALID_WINDOW_ID;
	if (event_from_window.is_valid()) {
		window_id = event_from_window->get_window_id();
	}
	get_singleton()->send_input_event(p_event, window_id);
}

void DisplayServerLibrary::send_input_event(const Ref<InputEvent> &p_event, DisplayServerEnums::WindowID p_window) const {
	if (p_window != DisplayServerEnums::INVALID_WINDOW_ID) {
		const NativeWindow *window = _get_window(p_window);
		if (window) {
			_call_window_callback(window->input_event_callback, p_event);
		}
		return;
	}

	for (const KeyValue<DisplayServerEnums::WindowID, NativeWindow> &entry : windows) {
		_call_window_callback(entry.value.input_event_callback, p_event);
	}
}

void DisplayServerLibrary::send_input_text(const String &p_text, DisplayServerEnums::WindowID p_window) const {
	const NativeWindow *window = _get_window(p_window);
	if (window) {
		_call_window_callback(window->input_text_callback, p_text);
	}
}

void DisplayServerLibrary::send_window_event(DisplayServerEnums::WindowEvent p_event, DisplayServerEnums::WindowID p_window) const {
	const NativeWindow *window = _get_window(p_window);
	if (window) {
		_call_window_callback(window->window_event_callback, int(p_event));
	}
}

void DisplayServerLibrary::_call_window_callback(const Callable &p_callback, const Variant &p_argument) const {
	if (p_callback.is_valid()) {
		p_callback.call(p_argument);
	}
}

void DisplayServerLibrary::_resize_rendering_surface(DisplayServerEnums::WindowID p_window, const Size2i &p_size_in_pixels) {
	#if defined(RD_ENABLED)
		rendering_context->window_set_size(p_window, p_size_in_pixels.width, p_size_in_pixels.height);
	#endif
}

void DisplayServerLibrary::touch_press(int p_idx, int p_x, int p_y, bool p_pressed, bool p_double_click, DisplayServerEnums::WindowID p_window) {
	Ref<InputEventScreenTouch> ev;
	ev.instantiate();
	ev->set_window_id(p_window);
	ev->set_index(p_idx);
	ev->set_pressed(p_pressed);
	ev->set_position(Vector2(p_x, p_y));
	ev->set_double_tap(p_double_click);
	_perform_event(ev);
}

void DisplayServerLibrary::touch_drag(int p_idx, int p_prev_x, int p_prev_y, int p_x, int p_y, float p_pressure, Vector2 p_tilt, DisplayServerEnums::WindowID p_window) {
	Ref<InputEventScreenDrag> ev;
	ev.instantiate();
	ev->set_window_id(p_window);
	ev->set_index(p_idx);
	ev->set_pressure(p_pressure);
	ev->set_tilt(p_tilt);
	ev->set_position(Vector2(p_x, p_y));
	ev->set_relative(Vector2(p_x - p_prev_x, p_y - p_prev_y));
	ev->set_relative_screen_position(ev->get_relative());
	_perform_event(ev);
}

void DisplayServerLibrary::touches_canceled(int p_idx, DisplayServerEnums::WindowID p_window) {
	touch_press(p_idx, -1, -1, false, false, p_window);
}

void DisplayServerLibrary::key(Key p_key, char32_t p_char, Key p_unshifted, Key p_physical, BitField<KeyModifierMask> p_modifiers, bool p_pressed, DisplayServerEnums::WindowID p_window) {
	Ref<InputEventKey> ev;
	ev.instantiate();
	ev->set_window_id(p_window);
	ev->set_echo(false);
	ev->set_pressed(p_pressed);
	ev->set_keycode(fix_keycode(p_char, p_key));
	if (p_key != Key::SHIFT) {
		ev->set_shift_pressed(p_modifiers.has_flag(KeyModifierMask::SHIFT));
	}
	if (p_key != Key::CTRL) {
		ev->set_ctrl_pressed(p_modifiers.has_flag(KeyModifierMask::CTRL));
	}
	if (p_key != Key::ALT) {
		ev->set_alt_pressed(p_modifiers.has_flag(KeyModifierMask::ALT));
	}
	if (p_key != Key::META) {
		ev->set_meta_pressed(p_modifiers.has_flag(KeyModifierMask::META));
	}
	ev->set_key_label(p_unshifted);
	ev->set_physical_keycode(p_physical);
	ev->set_unicode(fix_unicode(p_char));
	_perform_event(ev);
}

void DisplayServerLibrary::_perform_event(const Ref<InputEvent> &p_event) {
	Input::get_singleton()->parse_input_event(p_event);
}

bool DisplayServerLibrary::has_feature(DisplayServerEnums::Feature p_feature) const {
	switch (p_feature) {
#ifndef DISABLE_DEPRECATED
		case DisplayServerEnums::FEATURE_GLOBAL_MENU: {
			return (native_menu && native_menu->has_feature(NativeMenu::FEATURE_GLOBAL_MENU));
		} break;
#endif
		case DisplayServerEnums::FEATURE_MOUSE:
		case DisplayServerEnums::FEATURE_NATIVE_WINDOWS:
		case DisplayServerEnums::FEATURE_TOUCHSCREEN:
			return true;
		default:
			return false;
	}
}

String DisplayServerLibrary::get_name() const {
	return "library";
}

int DisplayServerLibrary::get_screen_count() const {
	return 1;
}

int DisplayServerLibrary::get_primary_screen() const {
	return 0;
}

Point2i DisplayServerLibrary::screen_get_position(int p_screen) const {
	return Point2i();
}

Size2i DisplayServerLibrary::screen_get_size(int p_screen) const {
	return window_get_size(DisplayServerEnums::MAIN_WINDOW_ID);
}

Rect2i DisplayServerLibrary::screen_get_usable_rect(int p_screen) const {
	return Rect2i(screen_get_position(p_screen), screen_get_size(p_screen));
}

int DisplayServerLibrary::screen_get_dpi(int p_screen) const {
	return 96;
}

float DisplayServerLibrary::screen_get_refresh_rate(int p_screen) const {
	return -1;
}

float DisplayServerLibrary::screen_get_max_scale() const {
	return screen_get_scale(DisplayServerEnums::SCREEN_OF_MAIN_WINDOW);
}

Vector<DisplayServerEnums::WindowID> DisplayServerLibrary::get_window_list() const {
	Vector<DisplayServerEnums::WindowID> window_ids;
	for (const KeyValue<DisplayServerEnums::WindowID, NativeWindow> &entry : windows) {
		window_ids.push_back(entry.key);
	}
	return window_ids;
}

DisplayServerEnums::WindowID DisplayServerLibrary::get_window_at_screen_position(const Point2i &p_position) const {
	return DisplayServerEnums::MAIN_WINDOW_ID;
}

int64_t DisplayServerLibrary::window_get_native_handle(DisplayServerEnums::HandleType p_handle_type, DisplayServerEnums::WindowID p_window) const {
	return 0;
}

void DisplayServerLibrary::window_attach_instance_id(ObjectID p_instance, DisplayServerEnums::WindowID p_window) {
	NativeWindow *window = _get_window(p_window);
	ERR_FAIL_NULL(window);
	window->attached_instance_id = p_instance;
}

ObjectID DisplayServerLibrary::window_get_attached_instance_id(DisplayServerEnums::WindowID p_window) const {
	const NativeWindow *window = _get_window(p_window);
	ERR_FAIL_NULL_V(window, ObjectID());
	return window->attached_instance_id;
}

void DisplayServerLibrary::window_set_title(const String &p_title, DisplayServerEnums::WindowID p_window) {
}

int DisplayServerLibrary::window_get_current_screen(DisplayServerEnums::WindowID p_window) const {
	return get_primary_screen();
}

void DisplayServerLibrary::window_set_current_screen(int p_screen, DisplayServerEnums::WindowID p_window) {
}

Point2i DisplayServerLibrary::window_get_position(DisplayServerEnums::WindowID p_window) const {
	return Point2i();
}

Point2i DisplayServerLibrary::window_get_position_with_decorations(DisplayServerEnums::WindowID p_window) const {
	return Point2i();
}

void DisplayServerLibrary::window_set_position(const Point2i &p_position, DisplayServerEnums::WindowID p_window) {
}

void DisplayServerLibrary::window_set_transient(DisplayServerEnums::WindowID p_window, DisplayServerEnums::WindowID p_parent) {
}

void DisplayServerLibrary::window_set_max_size(const Size2i p_size, DisplayServerEnums::WindowID p_window) {
}

Size2i DisplayServerLibrary::window_get_max_size(DisplayServerEnums::WindowID p_window) const {
	return Size2i();
}

void DisplayServerLibrary::window_set_min_size(const Size2i p_size, DisplayServerEnums::WindowID p_window) {
}

Size2i DisplayServerLibrary::window_get_min_size(DisplayServerEnums::WindowID p_window) const {
	return Size2i();
}

void DisplayServerLibrary::window_set_size(const Size2i p_size, DisplayServerEnums::WindowID p_window) {
}

Size2i DisplayServerLibrary::window_get_size(DisplayServerEnums::WindowID p_window) const {
#if defined(RD_ENABLED)
	if (rendering_context && windows.has(p_window)) {
		uint32_t width = 0;
		uint32_t height = 0;
		rendering_context->window_get_size(p_window, width, height);
		return Size2i(width, height);
	}
#endif
	return Size2i();
}

Size2i DisplayServerLibrary::window_get_size_with_decorations(DisplayServerEnums::WindowID p_window) const {
	return window_get_size(p_window);
}

void DisplayServerLibrary::window_set_mode(DisplayServerEnums::WindowMode p_mode, DisplayServerEnums::WindowID p_window) {
	NativeWindow *window = _get_window(p_window);
	ERR_FAIL_NULL(window);
	window->mode = p_mode;
}

DisplayServerEnums::WindowMode DisplayServerLibrary::window_get_mode(DisplayServerEnums::WindowID p_window) const {
	const NativeWindow *window = _get_window(p_window);
	ERR_FAIL_NULL_V(window, DisplayServerEnums::WINDOW_MODE_WINDOWED);
	return window->mode;
}

bool DisplayServerLibrary::window_is_maximize_allowed(DisplayServerEnums::WindowID p_window) const {
	return false;
}

void DisplayServerLibrary::window_set_flag(DisplayServerEnums::WindowFlags p_flag, bool p_enabled, DisplayServerEnums::WindowID p_window) {
	NativeWindow *window = _get_window(p_window);
	ERR_FAIL_NULL(window);
	uint32_t flag_bit = 1u << p_flag;
	if (p_enabled) {
		window->flags |= flag_bit;
	} else {
		window->flags &= ~flag_bit;
	}
}

bool DisplayServerLibrary::window_get_flag(DisplayServerEnums::WindowFlags p_flag, DisplayServerEnums::WindowID p_window) const {
	const NativeWindow *window = _get_window(p_window);
	ERR_FAIL_NULL_V(window, false);
	return window->flags & (1u << p_flag);
}

void DisplayServerLibrary::window_request_attention(DisplayServerEnums::WindowID p_window) {
}

void DisplayServerLibrary::window_move_to_foreground(DisplayServerEnums::WindowID p_window) {
}

bool DisplayServerLibrary::window_is_focused(DisplayServerEnums::WindowID p_window) const {
	return true;
}

bool DisplayServerLibrary::window_can_draw(DisplayServerEnums::WindowID p_window) const {
	return true;
}

bool DisplayServerLibrary::can_any_window_draw() const {
	return true;
}

void DisplayServerLibrary::window_set_vsync_mode(DisplayServerEnums::VSyncMode p_vsync_mode, DisplayServerEnums::WindowID p_window) {
}

DisplayServerEnums::VSyncMode DisplayServerLibrary::window_get_vsync_mode(DisplayServerEnums::WindowID p_window) const {
	return DisplayServerEnums::VSYNC_ENABLED;
}

bool DisplayServerLibrary::is_touchscreen_available() const {
	return true;
}

void DisplayServerLibrary::resize_window(Size2i p_size_in_pixels, DisplayServerEnums::WindowID p_window) {
	NativeWindow *window = _get_window(p_window);
	ERR_FAIL_NULL(window);
	window->surface->set_host_pixel_size(p_size_in_pixels);
	_resize_rendering_surface(p_window, p_size_in_pixels);
	_call_window_callback(window->rect_changed_callback, Rect2i(Point2i(), p_size_in_pixels));
}

void DisplayServerLibrary::mouse_set_mode(DisplayServerEnums::MouseMode p_mode) {
}

DisplayServerEnums::MouseMode DisplayServerLibrary::mouse_get_mode() const {
	return DisplayServerEnums::MOUSE_MODE_VISIBLE;
}

Point2i DisplayServerLibrary::mouse_get_position() const {
	return Input::get_singleton()->get_mouse_position();
}

BitField<MouseButtonMask> DisplayServerLibrary::mouse_get_button_state() const {
	return Input::get_singleton()->get_mouse_button_mask();
}
