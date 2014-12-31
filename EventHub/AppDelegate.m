//
//  AppDelegate.m
//  EventHub
//
//  Created by revin on Dec.29,2014.
//  Copyright (c) 2014 revin. All rights reserved.
//

#import "AppDelegate.h"
#import <AudioToolbox/AudioToolbox.h>

@interface AppDelegate()
@property(weak)IBOutlet NSWindow*window;
@property CFMachPortRef eventTap;
@property CGEventRef kd,ku;
@end
@implementation AppDelegate

bool optFilterCapslock;
//bool optFilterDelete;

bool smallHalt;CGEventFlags cachedEvFlags;
-(void)unhalt{smallHalt=false;}
CGEventRef eventCallback(CGEventTapProxy proxy,CGEventType type,CGEventRef event,AppDelegate*self){
    
    if(optFilterCapslock){
        if(type==kCGEventKeyDown||type==kCGEventKeyUp){
            CGEventFlags f=CGEventGetFlags(event);
            f&=~kCGEventFlagMaskAlphaShift;
            CGEventSetFlags(event,f);
        }else if(type==kCGEventFlagsChanged){
            if(!smallHalt){
                CGEventFlags newFlags=CGEventGetFlags(event);
                CGEventFlags diff=cachedEvFlags^newFlags;
                cachedEvFlags=newFlags;
                if(diff&kCGEventFlagMaskAlphaShift&&!(newFlags&kCGEventFlagMaskAlphaShift)){
                    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(unhalt)object:self];
                    smallHalt=true;
                    CGEventPost(kCGSessionEventTap,self.kd);
                    CGEventPost(kCGSessionEventTap,self.ku);
                    [self performSelector:@selector(unhalt)withObject:self afterDelay:0.3];
                }
            }
        }
    }
    
//    if(optFilterDelete){
//        // should be event keyChar
//        if(type==kCGEventKeyDown||type==kCGEventKeyUp){
////            int64_t isRepeat=CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat);
//            CGEventFlags f=CGEventGetFlags(event)&NSDeviceIndependentModifierFlagsMask;
//            f&=~(kCGEventFlagMaskAlphaShift|kCGEventFlagMaskSecondaryFn);
//            if(f==kCGEventFlagMaskShift){
//                int64_t keycode=CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
//                if(keycode==kVK_Delete||keycode==kVK_ForwardDelete){
//                    do{
//                        CFTypeRef elem=AXUIElementCreateSystemWide();
//                        if(AXUIElementCopyAttributeValue(elem,kAXFocusedUIElementAttribute,&elem))break;
//                        CFTypeRef role;if(AXUIElementCopyAttributeValue(elem,kAXRoleAttribute,&role))break;
//                        if(!CFEqual(kAXTextFieldRole,role)/*&&!CFEqual(kAXTextAreaRole,role)*/)break;
//                        do{
//                            // !!! for AXTextField(capable of multiple selection)
//                            // !!! beware of some selection is on the same line
//                            // !!! aaa [bbb] cc[c] like this, when delete
//                            CFTypeRef axrange;if(AXUIElementCopyAttributeValue(elem,kAXSelectedTextRangeAttribute,&axrange))break;
//                            CFTypeRef text;if(AXUIElementCopyAttributeValue(elem,kAXValueAttribute,&text))break;
//                            CFRange range;if(!AXValueGetValue(axrange,kAXValueCFRangeType,&range))break;
//                            if(keycode==kVK_ForwardDelete){
//                                CFTypeRef len;if(AXUIElementCopyAttributeValue(elem,kAXNumberOfCharactersAttribute,&len))break;
//                                range.length=[(__bridge NSNumber*)len longValue]-range.location;
//                            }else if(keycode==kVK_Delete){
//                                range.length+=range.location;
//                                range.location=0;
//                            }else break;
//                            axrange=AXValueCreate(kAXValueCFRangeType,&range);
//                            if(AXUIElementSetAttributeValue(elem,kAXSelectedTextRangeAttribute,axrange))break;
//                            if(AXUIElementSetAttributeValue(elem,kAXSelectedTextAttribute,@""))break;
//                            return nil;
//                        }while(false);
//                        AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert);
//                    }while(false);
//                }
//            }
//        }
//    }
    
    return event;
}

-(void)fatalWithText:(NSString*)msg{
    NSRunningApplication*ra=[NSRunningApplication currentApplication];
    NSAlert*alert=[NSAlert new];
    [alert addButtonWithTitle:@"Quit"];
    [alert setMessageText:[ra localizedName]];
    [alert setInformativeText:msg];
    [alert setAlertStyle:NSCriticalAlertStyle];
    [alert runModal];
    [NSApp terminate:self];
}
-(IBAction)quitApp:(id)sender{[NSApp terminate:sender];}
-(void)applicationDidFinishLaunching:(NSNotification*)aNotification{
    if(!AXIsProcessTrusted()){
        [self.window close];
        [self fatalWithText:@"Can't acquire Accessibility Permissions"];
        return;
    }
    CGEventRef kd=CGEventCreateKeyboardEvent(nil,kVK_CapsLock,true);
    CGEventRef ku=CGEventCreateKeyboardEvent(nil,kVK_CapsLock,false);
    if(!kd||!ku){
        if(kd)CFRelease(kd);
        if(ku)CFRelease(ku);
        [self.window close];
        [self fatalWithText:@"Can't initialize CGEvent"];
        return;
    }
    self.kd=kd;self.ku=ku;
}
-(void)applicationWillTerminate:(NSNotification*)aNotification{
    if(self.eventTap){
        CFRelease(self.eventTap);
        self.eventTap=nil;
    }
}
-(void)applicationDidResignActive:(NSNotification*)notification{
    CGEventMask interest=0;
    if(optFilterCapslock)interest|=CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp)|CGEventMaskBit(kCGEventFlagsChanged);
//    if(optFilterDelete)interest|=CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp);
    
    if(interest){
        self.eventTap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,interest,(CGEventTapCallBack)eventCallback,(__bridge void*)(self));
        if(self.eventTap){
            CFRunLoopSourceRef rp=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,self.eventTap,0);
            CFRunLoopAddSource(CFRunLoopGetMain(),rp,kCFRunLoopDefaultMode);
        }else[self fatalWithText:@"Can't create CGEventTap"];
        
        // if not selecting any insterests, keep the window
        ProcessSerialNumber psn={0,kCurrentProcess};
        TransformProcessType(&psn,kProcessTransformToUIElementApplication);
    }// else, not selecting any insterests, keep the window
}
// update configuration inside this file
-(void)applicationWillBecomeActive:(NSNotification*)notification{
    ProcessSerialNumber psn={0,kCurrentProcess};
    TransformProcessType(&psn,kProcessTransformToForegroundApplication);
    if(self.eventTap){
        CFRelease(self.eventTap);
        self.eventTap=nil;
    }
    // TODO add settings panel instead of hard-code options
    optFilterCapslock=true;
//    optFilterDelete=true;
}
@end
