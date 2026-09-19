#import "TVOSLifecycle.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <SDL3/SDL_hints.h>

namespace {

bool ContainsMenuPress(NSSet<UIPress*>* presses) {
    for (UIPress* press in presses) {
        if (press.type == UIPressTypeMenu) {
            return true;
        }
    }
    return false;
}

void ForwardToUIKit(id self, SEL selector, NSSet<UIPress*>* presses,
                    UIPressesEvent* event) {
    Class sdlView = NSClassFromString(@"SDL_uikitview");
    Class superClass = class_getSuperclass(sdlView);
    Method method = class_getInstanceMethod(superClass, selector);
    if (method == nullptr) {
        return;
    }
    using PressHandler = void (*)(id, SEL, NSSet<UIPress*>*, UIPressesEvent*);
    reinterpret_cast<PressHandler>(method_getImplementation(method))(
        self, selector, presses, event);
}

}  // namespace

@interface DuskTVOSBackBridge : NSObject

- (void)dusk_pressesBegan:(NSSet<UIPress*>*)presses
                withEvent:(UIPressesEvent*)event;
- (void)dusk_pressesEnded:(NSSet<UIPress*>*)presses
                withEvent:(UIPressesEvent*)event;
- (void)dusk_pressesCancelled:(NSSet<UIPress*>*)presses
                    withEvent:(UIPressesEvent*)event;

@end

@implementation DuskTVOSBackBridge

- (void)dusk_pressesBegan:(NSSet<UIPress*>*)presses
                withEvent:(UIPressesEvent*)event {
    if (ContainsMenuPress(presses) &&
        !DuskTVOSLifecycle_ShouldHandleBack()) {
        ForwardToUIKit(self, @selector(pressesBegan:withEvent:), presses, event);
        return;
    }
    [self dusk_pressesBegan:presses withEvent:event];
}

- (void)dusk_pressesEnded:(NSSet<UIPress*>*)presses
                withEvent:(UIPressesEvent*)event {
    if (ContainsMenuPress(presses) &&
        !DuskTVOSLifecycle_ShouldHandleBack()) {
        ForwardToUIKit(self, @selector(pressesEnded:withEvent:), presses, event);
        return;
    }
    [self dusk_pressesEnded:presses withEvent:event];
}

- (void)dusk_pressesCancelled:(NSSet<UIPress*>*)presses
                    withEvent:(UIPressesEvent*)event {
    if (ContainsMenuPress(presses) &&
        !DuskTVOSLifecycle_ShouldHandleBack()) {
        ForwardToUIKit(
            self, @selector(pressesCancelled:withEvent:), presses, event);
        return;
    }
    [self dusk_pressesCancelled:presses withEvent:event];
}

@end

void SwizzlePressHandler(Class target, SEL originalSelector,
                         SEL bridgeSelector) {
    Method original = class_getInstanceMethod(target, originalSelector);
    Method bridge =
        class_getInstanceMethod(DuskTVOSBackBridge.class, bridgeSelector);
    if (original == nullptr || bridge == nullptr) {
        return;
    }
    class_addMethod(target, bridgeSelector, method_getImplementation(bridge),
                    method_getTypeEncoding(bridge));
    Method installedBridge = class_getInstanceMethod(target, bridgeSelector);
    method_exchangeImplementations(original, installedBridge);
}

extern "C" void DuskTVOSLifecycle_Configure(void) {
    SDL_SetHint(SDL_HINT_TV_REMOTE_AS_JOYSTICK, "0");
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class sdlView = NSClassFromString(@"SDL_uikitview");
        if (sdlView == Nil) {
            return;
        }
        SwizzlePressHandler(
            sdlView, @selector(pressesBegan:withEvent:),
            @selector(dusk_pressesBegan:withEvent:));
        SwizzlePressHandler(
            sdlView, @selector(pressesEnded:withEvent:),
            @selector(dusk_pressesEnded:withEvent:));
        SwizzlePressHandler(
            sdlView, @selector(pressesCancelled:withEvent:),
            @selector(dusk_pressesCancelled:withEvent:));
    });
}
