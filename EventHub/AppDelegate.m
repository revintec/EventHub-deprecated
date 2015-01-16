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
@property NSMutableDictionary*options;
@end
@implementation AppDelegate

#define DOPT_DEFAULT_MODE          DOPT_AIRPORTEXTRA_ALT
#define DOPT_DISABLE_ALL_FILTERING DOPT_AIRPORTEXTRA_ALT
#define DOPT_FILTEROUT_CAPSLOCK    0x00000001
#define DOPT_AIRPORTEXTRA_ALT      0x00000002

AXUIElementRef axSystem;
unsigned int gopts,dopts;

static inline CGEventFlags ugcFlags(CGEventRef event){
    CGEventFlags f=CGEventGetFlags(event);
    f&=NSDeviceIndependentModifierFlagsMask;
    f&=~(kCGEventFlagMaskAlphaShift|kCGEventFlagMaskSecondaryFn);
    return f;
}
#define cc(errormsg,axerror) if(axerror){NSLog(@"%s: %d at %s(line %d)",errormsg,axerror,__PRETTY_FUNCTION__,__LINE__);AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert);break;}
CGEventRef eventCallback(CGEventTapProxy proxy,CGEventType type,CGEventRef event,AppDelegate*self){
    unsigned int opts=gopts&dopts;
    
    if(opts&DOPT_FILTEROUT_CAPSLOCK){
        if(type==kCGEventKeyDown||type==kCGEventKeyUp){
            CGEventFlags f=CGEventGetFlags(event);
            if(f&kCGEventFlagMaskAlphaShift){
                // KNOWN BUG: Chrome <input type="password"/>
                // won't respect our setting here.
                // if you input password while CAPSLOCK is on,
                // you'll enter all alphabet in upper case.
                // this can't be fixed with CGEventKeyboardSetUnicodeString
                f&=~kCGEventFlagMaskAlphaShift;
                CGEventSetFlags(event,f);
            }
        }
    }
    
    if(opts&DOPT_AIRPORTEXTRA_ALT)do{
        if(type==kCGEventLeftMouseDown){
            CGPoint point=CGEventGetLocation(event);
            // not in the upper-right corner, so can't hit AirPortExtra
            if(point.y>=22||point.x<=1000)break;
            AXUIElementRef elem;
            extern AXError _AXUIElementCopyElementAtPositionIncludeIgnored(AXUIElementRef root,float x,float y,AXUIElementRef*elem,long includingIgnored,long rcx,long r8,long r9);
            cc("AXUIElementCopyElementAtPositionEx",_AXUIElementCopyElementAtPositionIncludeIgnored
               (axSystem,point.x,point.y,&elem,false,0,0,0));
            CFTypeRef v;cc("AXUIECAV-ROLE",AXUIElementCopyAttributeValue(elem,kAXRoleAttribute,&v));
            if(!CFEqual(kAXMenuBarItemRole,v))break;
            AXError error=AXUIElementCopyAttributeValue(elem,(CFTypeRef)@"AXClassName",&v);
            if(error){
                if(kAXErrorAttributeUnsupported!=error)cc("AXUIECAV-AXCN",error);
                cc("AXUIECAV-DESC",AXUIElementCopyAttributeValue(elem,kAXDescriptionAttribute,&v));
                if(![(__bridge NSString*)v hasPrefix:@"Wi-Fi, "])break;
                CGEventFlags f=CGEventGetFlags(event);
                if(!(f&kCGEventFlagMaskAlternate)){
                    f|=kCGEventFlagMaskAlternate;
                    CGEventSetFlags(event,f);
                }
            }else{
                cc("I'm feeling lucky!",1);
                NSLog(@"%@",v);
            }
        }
    }while(false);
    
    return event;
}
-(void)someotherAppGotActivated:(NSNotification*)notification{
    NSDictionary*_n=[notification userInfo];if(!_n)return;
    NSRunningApplication*ra=[_n objectForKey:NSWorkspaceApplicationKey];if(!ra)return;
    NSString*name=[ra localizedName];
    NSNumber*opt=self.options[name];
    if(opt)dopts=[opt unsignedIntValue];
    else dopts=DOPT_DEFAULT_MODE;
    NSLog(@"dopt %@: %08x",name,dopts);
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
    axSystem=AXUIElementCreateSystemWide();
    NSNotificationCenter*ncc=[[NSWorkspace sharedWorkspace]notificationCenter];
    [ncc addObserver:self selector:@selector(someotherAppGotActivated:)name:NSWorkspaceDidActivateApplicationNotification object:nil];
}
-(void)undoAllChanges{
    dopts=0;
    if(self.eventTap){
        CFRelease(self.eventTap);
        self.eventTap=nil;
    }
}
-(void)applicationWillTerminate:(NSNotification*)aNotification{
    [self undoAllChanges];
}
-(void)applicationDidResignActive:(NSNotification*)notification{
    CGEventMask interest=0;
    if(gopts&DOPT_FILTEROUT_CAPSLOCK)interest|=CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp);
    if(gopts&DOPT_AIRPORTEXTRA_ALT)  interest|=CGEventMaskBit(kCGEventLeftMouseDown);
    
    if(interest){
        self.eventTap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,interest,(CGEventTapCallBack)eventCallback,(__bridge void*)self);
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
    [self undoAllChanges]; // temporary disable all functions when we're foreground
    // TODO add settings panel instead of hard-code options
    self.options=[NSMutableDictionary new];
#define setopt(app,opt) self.options[@app]=[NSNumber numberWithUnsignedInt:DOPT_DISABLE_ALL_FILTERING|opt]
    setopt("Remote Desktop Connection",DOPT_DISABLE_ALL_FILTERING);
    setopt("VMware Fusion",            DOPT_DISABLE_ALL_FILTERING);
    setopt("IntelliJ IDEA",            DOPT_FILTEROUT_CAPSLOCK);
    
    gopts=0xFFFFFFFF; // enable all filtering by default
}
@end
