//
//  AppDelegate.m
//  EventHub
//
//  Created by revin on Dec.29,2014.
//  Copyright (c) 2014 revin. All rights reserved.
//

#import "AppDelegate.h"
#import <IOKit/hid/IOHIDUsageTables.h>
#import <AudioToolbox/AudioToolbox.h>
#import "Safari.h"

@interface AppDelegate()
@property(weak)IBOutlet NSWindow*window;
@property CFMachPortRef eventTap;
@property NSMutableDictionary*options;
@end
@implementation AppDelegate

#define DOPT_DEFAULT_MODE          DOPT_AIRPORTEXTRA_ALT|DOPT_CMD_POWER_LOCKSCREEN|DOPT_SAFARI_DOUBANFM|DOPT_CMD_DEL_OVERRIDE
#define DOPT_DISABLE_ALL_FILTERING DOPT_AIRPORTEXTRA_ALT|DOPT_CMD_POWER_LOCKSCREEN|DOPT_SAFARI_DOUBANFM
#define DOPT_AIRPORTEXTRA_ALT      0x00000001
#define DOPT_CMD_POWER_LOCKSCREEN  0x00000002
//#define DOPT_FN_NUMPAD             0x00000004
#define DOPT_CMD_DEL_OVERRIDE      0x00000008
#define DOPT_SAFARI_DOUBANFM       0x00000010

ProcessSerialNumber myPsn={0,kCurrentProcess};
AXUIElementRef axSystem;
unsigned int gopts,dopts;

static inline CGEventFlags ugcFlags(CGEventRef event){
    CGEventFlags f=CGEventGetFlags(event);
    f&=NSDeviceIndependentModifierFlagsMask;
    f&=~(kCGEventFlagMaskAlphaShift|kCGEventFlagMaskSecondaryFn);
    return f;
}
#define cc(errormsg,axerror) {if(axerror){NSLog(@"%s: %d at %s(line %d)",errormsg,axerror,__PRETTY_FUNCTION__,__LINE__);AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert);break;}}
static inline int sleepDisplayNow(){
    kern_return_t error=KERN_FAILURE;
    do{
        io_registry_entry_t io=IORegistryEntryFromPath(kIOMasterPortDefault,"IOService:/IOResources/IODisplayWrangler");
        cc("IOREFP",io==MACH_PORT_NULL);
        error=IORegistryEntrySetCFProperty(io,(CFStringRef)@"IORequestIdle",kCFBooleanTrue);
        IOObjectRelease(io); // ignore error
        cc("IORESP",error);
        return KERN_SUCCESS;
    }while(false);
    AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert);
    return error;
}
static inline bool deleteToLineStart(AXUIElementRef elem){
    do{
        CFTypeRef axrange;cc("get SelectedTextRange",AXUIElementCopyAttributeValue(elem,kAXSelectedTextRangeAttribute,&axrange));
        CFRange range;cc("conv AXRange",!AXValueGetValue(axrange,kAXValueCFRangeType,&range));
        if(!range.length){
            range.length=range.location;
            range.location=0;
            axrange=AXValueCreate(kAXValueCFRangeType,&range);
            cc("set SelectedTextRange",AXUIElementSetAttributeValue(elem,kAXSelectedTextRangeAttribute,axrange))
        }cc("delete selected text",AXUIElementSetAttributeValue(elem,kAXSelectedTextAttribute,@""));
        return true;
    }while(false);
    return false;
}
static inline SafariTab*findDoubanFmTab(SafariApplication*app){
    for(SafariWindow*win in[app windows]){
        for(SafariTab*tab in[win tabs]){
            NSString*url=[tab URL];
            if([url hasPrefix:@"http://douban.fm/"])
                return tab;
        }
    }return nil;
}
int integrityCheck;
CGEventRef eventCallback(CGEventTapProxy proxy,CGEventType type,CGEventRef event,AppDelegate*self){
    unsigned int opts=gopts&dopts;
    
    #define FUCK_APPLE_CGEVENT_GET_SUBTYPE(event) (*(uint16_t*)((void*)event+0xa2))
    #define FUCK_APPLE_CGEVENT_GET_DATA1(event)   (*(uint32_t*)((void*)event+0xa4))
    #define FUCK_APPLE_CGEVENT_GET_DATA2(event)   (*(uint32_t*)((void*)event+0xa8))
    #define FUCK_APPLE_CGEVCOMPOUND_KEYDOWN   0x0a00
    #define FUCK_APPLE_CGEVCOMPOUND_KEYUP     0x0b00
    // we encounter NSSystemDefined more often, mouse click generates subType==7
    // so optimize to check integrityCheck first
    // if integrityCheck fails, stop all features and beep
    if(integrityCheck<=0){
        if(type==NSSystemDefined){
            NSEvent*ex=[NSEvent eventWithCGEvent:event];
            if([ex subtype]!=FUCK_APPLE_CGEVENT_GET_SUBTYPE(event)||
               [ex data1]!=FUCK_APPLE_CGEVENT_GET_DATA1(event)||
               [ex data2]!=FUCK_APPLE_CGEVENT_GET_DATA2(event)){
                integrityCheck=-1;
            }else integrityCheck=1;
        }if(integrityCheck<0){
            NSLog(@"%s: failed at %s(line %d)","event structure integrity check",__PRETTY_FUNCTION__,__LINE__);
            AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert);
            return event;
        }
    }
    
    if(opts&DOPT_CMD_POWER_LOCKSCREEN)do{
        if(type==NSSystemDefined){
            NSEventSubtype sub=FUCK_APPLE_CGEVENT_GET_SUBTYPE(event);
            if(sub==NX_SUBTYPE_POWER_KEY){
                // power button should have its data1 and data2 both equal 0
                if(!FUCK_APPLE_CGEVENT_GET_DATA1(event)&&!FUCK_APPLE_CGEVENT_GET_DATA2(event)){
                    CGEventFlags flags=ugcFlags(event);
                    if(flags==kCGEventFlagMaskCommand){
                        sleepDisplayNow();
                        // no need to kill this event
                        // system still beeps even if we do
                        // return nil;
                    }
                }
            }
        }
    }while(false);
    
    if(opts&DOPT_AIRPORTEXTRA_ALT)do{
        if(type==NSLeftMouseDown){
            CGPoint point=CGEventGetLocation(event); // 0,0 at upper-left
            // not in the upper-right corner, so can't hit AirPortExtra
            // DynamicLyrics.app's, Bartender.app's MenuBarExtra donesn't
            // have kAXDescriptionAttribute, and will cause our app to bailout
            // so we constrain point.x to 1200~1300
            if(point.y>=22||point.x<=1200||point.x>=1300)break;
            AXUIElementRef elem;
            extern AXError _AXUIElementCopyElementAtPositionIncludeIgnored(AXUIElementRef root,float x,float y,AXUIElementRef*elem,long includingIgnored,long rcx,long r8,long r9);
            cc("AXUIElementCopyElementAtPositionEx",_AXUIElementCopyElementAtPositionIncludeIgnored
               (axSystem,point.x,point.y,&elem,false,0,0,0));
            CFTypeRef v;cc("AXUIECAV-ROLE",AXUIElementCopyAttributeValue(elem,kAXRoleAttribute,&v));
            if(!CFEqual(kAXMenuBarItemRole,v))break;
            // fuck Apple! again and again!
            // AXError error=AXUIElementCopyAttributeValue(elem,(CFTypeRef)@"AXClassName",&v);
            cc("AXUIECAV-DESC",AXUIElementCopyAttributeValue(elem,kAXDescriptionAttribute,&v));
            if(![(__bridge NSString*)v hasPrefix:@"Wi-Fi, "])break;
            CGEventFlags f=CGEventGetFlags(event);
            if(!(f&kCGEventFlagMaskAlternate)){
                f|=kCGEventFlagMaskAlternate;
                CGEventSetFlags(event,f);
            }
        }
    }while(false);
    
//    if(opts&DOPT_FN_NUMPAD)do{
//        if(type==NSEventMaskGesture||type==NSEventMaskBeginGesture||type==NSEventMaskEndGesture){
//            NSTouchEventSubtype
//            NSEvent*ev=[NSEvent eventWithCGEvent:event];
//            NSSet*touches=[ev touchesMatchingPhase:NSTouchPhaseEnded inView:nil];
//            for(NSTouch*t in touches){
//                NSPoint pt=[t normalizedPosition];
//                NSLog(@"%f,%f",pt.x,pt.y);
//            }
//        }
//    }while(false);
    
    if(opts&DOPT_SAFARI_DOUBANFM)do{
        if(type==NSSystemDefined){
            NSEventSubtype sub=FUCK_APPLE_CGEVENT_GET_SUBTYPE(event);
            if(sub==NX_SUBTYPE_AUX_CONTROL_BUTTONS){
                int data2=FUCK_APPLE_CGEVENT_GET_DATA2(event);
                cc("NX_AUX_MEDIA data2!=-1",data2!=-1);
                int data1=FUCK_APPLE_CGEVENT_GET_DATA1(event);
                int keyCode=data1>>16;
                if(keyCode!=NX_KEYTYPE_PLAY)break;
                NSString*safariBundleId=@"com.apple.Safari";
                NSArray*ras=[NSRunningApplication runningApplicationsWithBundleIdentifier:safariBundleId];
                if(![ras count])break;
                SafariApplication*app=[SBApplication applicationWithBundleIdentifier:safariBundleId];
                SafariTab*tab=findDoubanFmTab(app);
                if(!tab)break;
                if((data1&0xFFFF)==FUCK_APPLE_CGEVCOMPOUND_KEYDOWN)
                    [app doJavaScript:@"DBR.act('pause')"in:tab];
                return nil;
            }
        }
    }while(false);
    
    // CMD-DEL still deletes file in other app's open/save dialog if we hook Finder.app only
    if(opts&DOPT_CMD_DEL_OVERRIDE)do{
        if(type==NSKeyDown||type==NSKeyUp){
            int64_t keycode=CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
            if(keycode==kVK_Delete){
                CGEventFlags f=ugcFlags(event);
                if(f==kCGEventFlagMaskCommand){
                    // don't use cc(AXUIE...), some app won't support Accessibility
                    CFTypeRef elem;if(AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),kAXFocusedUIElementAttribute,&elem))break;
                    CFTypeRef role;if(AXUIElementCopyAttributeValue(elem,kAXRoleAttribute,&role))break;
                    if(!CFEqual(kAXTextFieldRole,role))break;
//                    CFTypeRef className;
//                    if(!AXUIElementCopyAttributeValue(elem,(CFTypeRef)@"AXClassName",&className)){
//                        NSLog(@"AXClassName: %@",className);
//                        if(!CFEqual(@"TShrinkToFitTextView",className))break;
//                    }
                    if(type==NSKeyDown)deleteToLineStart(elem);
                    return nil;
                }
            }
        }
    }while(false);
    
    return event;
}
-(void)someotherAppGotActivated:(NSNotification*)notification{
    if(!self.window)return;
    NSDictionary*_n=[notification userInfo];if(!_n)return;
    NSRunningApplication*ra=[_n objectForKey:NSWorkspaceApplicationKey];if(!ra)return;
    NSString*name=[ra localizedName];
    NSNumber*opt=self.options[name];
    if(opt)dopts=[opt unsignedIntValue];
    else dopts=DOPT_DEFAULT_MODE;
    NSLog(@"dopt %@: %08x",name,dopts);
}
-(void)fatalWithText:(NSString*)msg{
    NSLog(@"fatal: %@",msg);
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
#pragma mark HID
static inline CFDictionaryRef createMatchingDict(bool isDevice,uint32_t inUsagePage,uint32_t inUsage){
    if(inUsagePage){
        NSMutableDictionary*dic=[NSMutableDictionary new];
        id keyPage=(__bridge id)(isDevice?CFSTR(kIOHIDDeviceUsagePageKey):CFSTR(kIOHIDElementUsagePageKey));
        dic[keyPage]=[NSNumber numberWithUnsignedInt:inUsagePage];
        // note: the usage is only valid if the usage page is also defined
        if(inUsage){
            id keyUsage=(__bridge id)(isDevice?CFSTR(kIOHIDDeviceUsageKey):CFSTR(kIOHIDElementUsageKey));
            dic[keyUsage]=[NSNumber numberWithUnsignedInt:inUsage];
        }return CFBridgingRetain(dic);
    }return nil;
}
IOHIDDeviceRef devKeyboard;IOHIDElementRef elemKeyboardLedCapslock;
IOHIDValueRef oofON,oofOFF;
static inline void initializeHID(){
    IOHIDManagerRef mgr=IOHIDManagerCreate(kCFAllocatorDefault,kIOHIDOptionsTypeNone);
    if(!mgr)return;
    CFDictionaryRef criteria=createMatchingDict(true,kHIDPage_GenericDesktop,kHIDUsage_GD_Keyboard);
    IOHIDManagerSetDeviceMatching(mgr,criteria);
    CFRelease(criteria);
    if(kIOReturnSuccess!=IOHIDManagerOpen(mgr,kIOHIDOptionsTypeNone)){IOHIDManagerClose(mgr,kIOHIDOptionsTypeNone);return;}
    CFSetRef devices=IOHIDManagerCopyDevices(mgr);
    IOHIDManagerClose(mgr,kIOHIDOptionsTypeNone);
    if(!devices)return;
    CFIndex count=CFSetGetCount(devices);
    NSLog(@"%ld devices found",count);
    if(count==1)CFSetGetValues(devices,(void*)&devKeyboard);
    CFRelease(devices);
    if(!devKeyboard)return;
    if(kIOReturnSuccess!=IOHIDDeviceOpen(devKeyboard,kIOHIDOptionsTypeNone)){
        devKeyboard=nil;
        return;
    }
    criteria=createMatchingDict(false,kHIDPage_LEDs,kHIDUsage_LED_CapsLock);
    CFArrayRef elems=IOHIDDeviceCopyMatchingElements(devKeyboard,criteria,kIOHIDOptionsTypeNone);
    count=CFArrayGetCount(elems);
    NSLog(@"with %ld elements",count);
    if(count==1)elemKeyboardLedCapslock=(void*)CFArrayGetValueAtIndex(elems,0);
    CFRelease(elems);
    if(elemKeyboardLedCapslock){
        oofON=IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault,elemKeyboardLedCapslock,0,true);
        oofOFF=IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault,elemKeyboardLedCapslock,0,false);
    }else{
        IOHIDDeviceClose(devKeyboard,kIOHIDOptionsTypeNone);
        devKeyboard=nil;
    }
}
static inline bool setCapslockLED(bool on){
    return kIOReturnSuccess==IOHIDDeviceSetValue(devKeyboard,elemKeyboardLedCapslock,on?oofON:oofOFF);
}
#pragma mark end HID
-(void)applicationDidFinishLaunching:(NSNotification*)aNotification{
#define ccc(msg,cond) {if(cond){errorMsg=@msg;break;}}
    NSString*errorMsg;
    do{
        ccc("Can't acquire Accessibility Permissions",!AXIsProcessTrusted());
        initializeHID();
        ccc("Error initializing HID",!devKeyboard||!elemKeyboardLedCapslock);
        axSystem=AXUIElementCreateSystemWide();
        NSNotificationCenter*ncc=[[NSWorkspace sharedWorkspace]notificationCenter];
        [ncc addObserver:self selector:@selector(someotherAppGotActivated:)name:NSWorkspaceDidActivateApplicationNotification object:nil];
        return;
    }while(false);
    [self.window close];
    self.window=nil;
    [self fatalWithText:errorMsg];
}
-(void)undoAllChanges{
    dopts=0;
    if(self.eventTap){
        CGEventTapEnable(self.eventTap,false);
        CFRelease(self.eventTap);
        self.eventTap=nil;
    }setCapslockLED(false);
}
-(void)applicationWillTerminate:(NSNotification*)aNotification{
    if(!self.window)return;
    [self undoAllChanges];
    if(devKeyboard)IOHIDDeviceClose(devKeyboard,kIOHIDOptionsTypeNone);
}
-(void)applicationDidResignActive:(NSNotification*)notification{
    if(!self.window)return;
    CGEventMask interest=0;
    // though we're only interested in NSLeftMouseDown, we have to register NSLeftMouseUp
    // or else NSLeftMouseUp may reach the app before we've done processing NSLeftMouseDown
    if(gopts&DOPT_AIRPORTEXTRA_ALT)    interest|=NSLeftMouseDownMask|NSLeftMouseUpMask;
    if(gopts&DOPT_CMD_POWER_LOCKSCREEN)interest|=NSSystemDefinedMask;
//    if(gopts&DOPT_FN_NUMPAD)           interest|=NSEventMaskGesture|NSEventMaskBeginGesture|NSEventMaskEndGesture;
    if(gopts&DOPT_CMD_DEL_OVERRIDE)    interest|=NSKeyDownMask|NSKeyUpMask;
    if(gopts&DOPT_SAFARI_DOUBANFM)     interest|=NSKeyDownMask|NSKeyUpMask;
    
    if(interest){
        self.eventTap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionDefault,interest,(CGEventTapCallBack)eventCallback,(__bridge void*)self);
        if(self.eventTap){
            CFRunLoopSourceRef rp=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,self.eventTap,0);
            CFRunLoopAddSource(CFRunLoopGetMain(),rp,kCFRunLoopDefaultMode);
        }else[self fatalWithText:@"Can't create CGEventTap"];
        // if not selecting any insterests, keep the window
        TransformProcessType(&myPsn,kProcessTransformToUIElementApplication);
        setCapslockLED(true);
    }// else, not selecting any insterests, keep the window
}
// update configuration inside this file
-(void)applicationWillBecomeActive:(NSNotification*)notification{
    if(!self.window)return;
    TransformProcessType(&myPsn,kProcessTransformToForegroundApplication);
    [self undoAllChanges]; // temporary disable all functions when we're foreground
    // TODO add settings panel instead of hard-code options
    self.options=[NSMutableDictionary new];
#define setopt(app,opt) self.options[@app]=[NSNumber numberWithUnsignedInt:DOPT_DISABLE_ALL_FILTERING|opt]
    setopt("Remote Desktop Connection",DOPT_DISABLE_ALL_FILTERING);
    setopt("VMware Fusion",            DOPT_DISABLE_ALL_FILTERING);
    
    gopts=0xFFFFFFFF; // enable all filtering by default
}
@end
