/**************************************************************************/
/*  libgodot_compositor_services_controller.h                             */
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

#pragma once

#include "core/object/ref_counted.h"
#include "servers/rendering/rendering_native_surface.h"

// Lets a libgodot host hand the Compositor Services layer renderers of its immersive spaces to Godot.
// The controller exists for the whole lifetime of the engine: its main window surface is given to
// DisplayServerLibrary before the engine starts, and immersive sessions come and go on top of it while
// host windows keep rendering through their own RenderingNativeSurfaceApple surfaces.
class LibgodotCompositorServicesController : public RefCounted {
	GDCLASS(LibgodotCompositorServicesController, RefCounted);

	Ref<RenderingNativeSurface> main_window_surface;
	void *active_session = nullptr;

protected:
	static void _bind_methods();

public:
	static Ref<LibgodotCompositorServicesController> create();

	Ref<RenderingNativeSurface> get_main_window_surface() const;

	void begin_session(uint64_t p_layer_renderer, float p_minimum_near_plane_distance);
	void run_render_loop();
	void end_session();
	void world_recentered();

	bool is_session_active() const;
	bool is_presenting_frames() const;

	~LibgodotCompositorServicesController();
};
