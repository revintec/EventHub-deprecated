//
//  AppDelegate.m
//  EventHub
//
//  Created by revin on Dec.29,2014.
//  Copyright (c) 2014 revin. All rights reserved.
//

#import "AppDelegate.h"
#import <objc/runtime.h>
#import <AudioToolbox/AudioToolbox.h>

@interface AppDelegate()
@property(weak)IBOutlet NSWindow*window;
@property CFMachPortRef eventTap;
@property CGEventRef kd,ku;
@end

@implementation AppDelegate
static inline OSStatus _GetProcessForPID(pid_t pid,ProcessSerialNumber*psn){
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return GetProcessForPID(pid,psn);
#pragma clang diagnostic pop
}
bool strokeKeycodeWithModifier(ProcessSerialNumber*psn,CGEventFlags modifiers,CGKeyCode key){
    CGEventRef kd=CGEventCreateKeyboardEvent(nil,key,true);
    CGEventRef ku=CGEventCreateKeyboardEvent(nil,key,false);
    if(!kd||!ku){
        if(kd)CFRelease(kd);
        if(ku)CFRelease(ku);
        return false;
    }
    CGEventSetFlags(kd,modifiers);
    CGEventSetFlags(ku,modifiers);
    if(psn){
        CGEventPostToPSN(psn,kd);
        CGEventPostToPSN(psn,ku);
    }else{
        CGEventPost(kCGSessionEventTap,kd);
        CGEventPost(kCGSessionEventTap,ku);
    }CFRelease(kd);CFRelease(ku);
    return true;
}

bool optFilterCapslock;
bool optFilterCmdDelFinder;
    bool doptFinderFg;
    ProcessSerialNumber psnFinder;

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
    
    if(optFilterCmdDelFinder&&doptFinderFg){
        if(type==kCGEventKeyDown||type==kCGEventKeyUp){
            int64_t keycode=CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
            if(keycode==kVK_Delete){
                CGEventFlags f=CGEventGetFlags(event)&NSDeviceIndependentModifierFlagsMask;
                f&=~kCGEventFlagMaskAlphaShift;
                if(f==kCGEventFlagMaskCommand){
                    if(type==kCGEventKeyUp){
                        CFTypeRef elem=AXUIElementCreateSystemWide();
                        if(AXUIElementCopyAttributeValue(elem,kAXFocusedUIElementAttribute,&elem))return nil;
                        CFTypeRef role;if(AXUIElementCopyAttributeValue(elem,kAXRoleAttribute,&role))return nil;
                        if(!CFEqual(kAXTextFieldRole,role)){NSLog(@"ignore CmdDel on non TextField role in Finder");return nil;}
                        CFTypeRef className;
                        if(AXUIElementCopyAttributeValue(elem,(CFTypeRef)@"AXClassName",&className)){
                            NSLog(@"unable to get AXClassName, fuck apple x1");
                            strokeKeycodeWithModifier(&psnFinder,kCGEventFlagMaskShift,kVK_Home);
                            strokeKeycodeWithModifier(&psnFinder,0,kVK_Delete);
                        }else{
                            NSLog(@"AXClassName: %@",className);
                            if(CFEqual(@"TShrinkToFitTextView",className)){
                                strokeKeycodeWithModifier(&psnFinder,kCGEventFlagMaskShift,kVK_Home);
                                strokeKeycodeWithModifier(&psnFinder,0,kVK_Delete);
                            }else NSLog(@"not a TShrinkToFitTextView");
                        }
                    }return nil;
                }
            }
        }
    }
    
    return event;
}

-(void)someotherAppGotActivated:(NSNotification*)notification{
    NSDictionary*_n=[notification userInfo];if(!_n)return;
    NSRunningApplication*ra=[_n objectForKey:NSWorkspaceApplicationKey];if(!ra)return;
    NSString*name=[ra localizedName];
    if([@"Finder" isEqual:name]){
        // _GetProcessForPID returns OSStatus if error
        // set doptFinderFg only when no error
        doptFinderFg=!_GetProcessForPID([ra processIdentifier],&psnFinder);
        if(!doptFinderFg){
            NSLog(@"unable to get Finder's PSN, will disable CmdDel filter in Finder");
            AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert);
        }
    }else doptFinderFg=false;
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
-(void)dumpInfo:(id)obj{
    Class clazz=[obj class];
    u_int count;
    Ivar*ivars=class_copyIvarList(clazz,&count);
    NSMutableArray*ivarArray=[NSMutableArray arrayWithCapacity:count];
    for(int i=0;i<count;++i){
        const char*ivarName=ivar_getName(ivars[i]);
        [ivarArray addObject:[NSString stringWithCString:ivarName encoding:NSUTF8StringEncoding]];
    }free(ivars);
    
    objc_property_t*properties=class_copyPropertyList(clazz,&count);
    NSMutableArray*propertyArray=[NSMutableArray arrayWithCapacity:count];
    for(int i=0;i<count;++i){
        const char*propertyName=property_getName(properties[i]);
        [propertyArray addObject:[NSString stringWithCString:propertyName encoding:NSUTF8StringEncoding]];
    }free(properties);
    
    Method*methods=class_copyMethodList(clazz,&count);
    NSMutableArray*methodArray=[NSMutableArray arrayWithCapacity:count];
    for(int i=0;i<count;++i){
        SEL selector=method_getName(methods[i]);
        const char*methodName=sel_getName(selector);
        [methodArray addObject:[NSString stringWithCString:methodName encoding:NSUTF8StringEncoding]];
    }free(methods);
    
    NSDictionary*classDump=[NSDictionary dictionaryWithObjectsAndKeys:
                               ivarArray,@"ivars",
                               propertyArray,@"properties",
                               methodArray,@"methods",
                               nil];
    NSLog(@"%@", classDump);
}
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
    NSNotificationCenter*ncc=[[NSWorkspace sharedWorkspace]notificationCenter];
    [ncc addObserver:self selector:@selector(someotherAppGotActivated:)name:NSWorkspaceDidActivateApplicationNotification object:nil];
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
    if(optFilterCmdDelFinder)interest|=CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp);
    
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
    optFilterCmdDelFinder=true;
}
@end
