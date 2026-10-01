/**************************************************************************/
/*  rendering_native_surface_apple.mm                                     */
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

#import <QuartzCore/CAMetalLayer.h>

#include "rendering_native_surface_apple.h"
#include "drivers/metal/rendering_context_driver_metal.h"

void RenderingNativeSurfaceApple::_bind_methods() {
    ClassDB::bind_static_method("RenderingNativeSurfaceApple", D_METHOD("create", "layer"), &RenderingNativeSurfaceApple::create_api);
    ClassDB::bind_method(D_METHOD("get_layer"), &RenderingNativeSurfaceApple::get_layer);
}

Ref<RenderingNativeSurfaceApple> RenderingNativeSurfaceApple::create_api(uint64_t p_layer) {
    return RenderingNativeSurfaceApple::create((void *)p_layer);
}

Ref<RenderingNativeSurfaceApple> RenderingNativeSurfaceApple::create(void *p_layer) {
    Ref<RenderingNativeSurfaceApple> result;

    if (!p_layer) {
        CALayer* __block myLayer = nil;

        if ([NSThread isMainThread]) {
            myLayer = [[CAMetalLayer alloc] init];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                myLayer = [[CAMetalLayer alloc] init];
            });
        }

        if (!myLayer) {
            return result;
        }

        p_layer = (void *) CFBridgingRetain(myLayer);
    } else {
        p_layer = (void *) CFBridgingRetain((__bridge CALayer *) p_layer);
    }

    result.instantiate();
    result->layer = p_layer;
    return result;
}
uint64_t RenderingNativeSurfaceApple::get_layer() {
    return (uint64_t)layer;
}

RenderingContextDriver *RenderingNativeSurfaceApple::create_rendering_context(const String &p_rendering_driver) {
#if defined(METAL_ENABLED)
	if (p_rendering_driver == "metal") {
		if (@available(ios 14.0, *)) {
			return memnew(RenderingContextDriverMetal);
		}
	}
#endif
	return nullptr;
}

RenderingNativeSurfaceApple::~RenderingNativeSurfaceApple() {
    if (layer) {
        CFBridgingRelease(layer);
    }
}
