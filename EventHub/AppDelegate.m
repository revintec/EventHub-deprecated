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
#import <SecurityFoundation/SFAuthorization.h>

#import "ProtocolCodes.h"

@interface AppDelegate()
@property(weak)IBOutlet NSWindow*window;
@property CFMachPortRef eventTap;
@property NSMutableDictionary*options;
@end
@implementation AppDelegate

#define DOPT_DEFAULT_MODE          DOPT_AIRPORTEXTRA_ALT|DOPT_POWER_LOCKSCREEN
#define DOPT_DISABLE_ALL_FILTERING DOPT_AIRPORTEXTRA_ALT|DOPT_POWER_LOCKSCREEN
#define DOPT_AIRPORTEXTRA_ALT      0x00000001
#define DOPT_POWER_LOCKSCREEN      0x00000002

AuthorizationRef authorization;
pid_t daemonpid;FILE*daemonfile;
ProcessSerialNumber myPsn={0,kCurrentProcess};
AXUIElementRef axSystem;
unsigned int gopts,dopts;
CGEventRef cgevFPCD,cgevFPCU; // used to trigger Ctrl-DN-UP-DN-UP sequence when mouse clicks

static inline OSStatus _AuthorizationExecuteWithPrivileges(
       AuthorizationRef authorization,
       const char*pathToTool,
       AuthorizationFlags options,
       char*const*arguments,
       FILE**communicationsPipe){
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return AuthorizationExecuteWithPrivileges(authorization,pathToTool,options,arguments,communicationsPipe);
#pragma clang diagnostic pop
}
uint32_t daemonTransactionSerial=1;
static inline void daemonDestroy(){
    fclose(daemonfile);
    daemonfile=nil;
    daemonpid=0;
}
/*! return -1 means IOError, and all further transaction will fail */
static inline int daemonTransact(uint32_t opcode){
    if(!daemonfile)return -1;
    uint32_t commbuffer[2];
    uint32_t transaction=daemonTransactionSerial;
    commbuffer[0]=transaction;
    commbuffer[1]=opcode;
    do{
        if(1!=fwrite(&commbuffer,sizeof(commbuffer),1,daemonfile))break;
        if(1!=fread(&commbuffer,sizeof(commbuffer),1,daemonfile))break;
        if(transaction!=daemonTransactionSerial)break; // reentrant failure
        if(commbuffer[0]!=transaction)break; // comm failure
        ++daemonTransactionSerial; // should use atomic inc
        if(commbuffer[1]==-1)break; // daemon failure
        return commbuffer[1];
    }while(false);
    daemonDestroy();
    return -1;
}
static inline CGEventFlags ugcFlags(CGEventRef event){
    CGEventFlags f=CGEventGetFlags(event);
    f&=NSDeviceIndependentModifierFlagsMask;
    f&=~(kCGEventFlagMaskAlphaShift|kCGEventFlagMaskSecondaryFn);
    return f;
}
CGEventTimestamp powerDown;
#define cc(errormsg,axerror) {if(axerror){NSLog(@"%s: %d at %s(line %d)",errormsg,axerror,__PRETTY_FUNCTION__,__LINE__);AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert);break;}}
#define xx(errormsg,axerror) {if(axerror){NSLog(@"%s: %x at %s(line %d)",errormsg,axerror,__PRETTY_FUNCTION__,__LINE__);AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert);break;}}
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
static inline int sleepSystemNow(){
    return -1;
}
CGEventRef eventCallback(CGEventTapProxy proxy,CGEventType type,CGEventRef event,AppDelegate*self){
    unsigned int opts=gopts&dopts;
    
    // defaults write com.apple.loginwindow PowerButtonSleepsSystem -bool false
    if(opts&DOPT_POWER_LOCKSCREEN)do{
        if(type==NSSystemDefined){
            NSEvent*ex=[NSEvent eventWithCGEvent:event];
            NSEventSubtype sub=ex.subtype;
            if(sub==NX_SUBTYPE_AUX_CONTROL_BUTTONS){
                NSUInteger data1=ex.data1;
                CGKeyCode keycode=data1>>16;
                // power button should have its ex.data2 0
                if(keycode==NX_POWER_KEY&&!ex.data2){
                    NSLog(@"got power event");
                    CGKeyCode flags=data1&0xFF00;
                    // CGKeyCode isRepeat=data1&0xFF; // should be 0x01 or 0x00, check it against other values
#define SPECIAL_KEY_DOWN 0x0a00
#define SPECIAL_KEY_UP   0x0b00
                    switch(flags){
                        case SPECIAL_KEY_DOWN:
                            cc("check last power down time",!!powerDown);
                            powerDown=CGEventGetTimestamp(event)/1000000;
                            break;
                        case SPECIAL_KEY_UP:
                            NSLog(@"resume loginwindow");
                            cc("resume loginwindow",daemonTransact(PROTO_RESUME_LOGINWINDOW));
                            // disassemble from /System/Library/CoreServices/loginwindow.app
#define _powerButtonDebounceTime ((int)(0.35*1000))
#define _powerButtonShutdownUITime ((int)(1.5*1000))
                            cc("check last power down time",!powerDown);
                            powerDown=CGEventGetTimestamp(event)/1000000-powerDown;
                            NSLog(@"%d ms",(int)powerDown);
                            if(powerDown>_powerButtonDebounceTime){
                                if(powerDown<_powerButtonShutdownUITime){
                                    cc("sleepDisplayNow",sleepDisplayNow());
                                }else cc("sleepSystemNow",sleepSystemNow());
                            }powerDown=0;
                            break;
                        default:
                            xx("unknown flags",flags);
                            break;
                    }
                }
            }else if(sub==NX_SUBTYPE_POWER_KEY){
                // power button should have its ex.dataX 0
                if(!ex.data1&&!ex.data2){
                    CGEventFlags flags=ugcFlags(event);
                    if(flags==kCGEventFlagMaskCommand){
                        cc("sleepSystemNow",sleepSystemNow());
                    }else if(!flags){
                        NSLog(@"suspend loginwindow");
                        // seems too late, by the time we suspend it
                        // it already got NX_SUBTYPE_AUX_CONTROL_BUTTONS(keycode PowerButton)
                        cc("suspend loginwindow",daemonTransact(PROTO_SUSPEND_LOGINWINDOW));
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
-(IBAction)quitApp:(id)sender{
    daemonTransact(PROTO_SHUTDOWN_DAEMON);
    [NSApp terminate:sender];
}
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
    {
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
    }if(!devKeyboard)return;
    if(kIOReturnSuccess!=IOHIDDeviceOpen(devKeyboard,kIOHIDOptionsTypeNone)){
        devKeyboard=nil;
        return;
    }
    {
        CFDictionaryRef criteria=createMatchingDict(false,kHIDPage_LEDs,kHIDUsage_LED_CapsLock);
        CFArrayRef elems=IOHIDDeviceCopyMatchingElements(devKeyboard,criteria,kIOHIDOptionsTypeNone);
        CFIndex count=CFArrayGetCount(elems);
        NSLog(@"with %ld elements",count);
        if(count==1)elemKeyboardLedCapslock=(void*)CFArrayGetValueAtIndex(elems,0);
        CFRelease(elems);
    }if(!elemKeyboardLedCapslock)return;
    oofON= IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault,elemKeyboardLedCapslock,0,true);
    oofOFF=IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault,elemKeyboardLedCapslock,0,false);
}
static inline bool setCapslockLED(bool on){
    return kIOReturnSuccess==IOHIDDeviceSetValue(devKeyboard,elemKeyboardLedCapslock,on?oofON:oofOFF);
}
#pragma mark end HID
static inline bool startDaemon(){
    do{
        NSBundle*bundle=[NSBundle mainBundle];
        NSString*execpath=[bundle executablePath];
        char*argv[]={"-daemon",nil};
        OSStatus error=_AuthorizationExecuteWithPrivileges(authorization,[execpath UTF8String],0,argv,&daemonfile);
        if(errAuthorizationSuccess!=error)return false;
        // hand-shake
        pid_t mypid=getpid();
        if(1!=fwrite(&mypid,sizeof(mypid),1,daemonfile)||1!=fread(&daemonpid,sizeof(daemonpid),1,daemonfile))break;
        NSLog(@"daemon(pid %d) attached to %d",daemonpid,mypid);
        pid_t loginwindow=daemonTransact(PROTO_VALIDATE_LOGINWINDOW);
        if(loginwindow<=0)break;
        NSLog(@"loginwindow pid according to daemon: %d",loginwindow);
        return true;
    }while(false);
    if(daemonfile)daemonDestroy();
    return false;
}
-(void)applicationDidFinishLaunching:(NSNotification*)aNotification{
    if(errAuthorizationSuccess!=AuthorizationCreate(nil,kAuthorizationEmptyEnvironment,
            kAuthorizationFlagExtendRights|kAuthorizationFlagInteractionAllowed,&authorization)){
        [self.window close];
        self.window=nil;
        [self fatalWithText:@"Authorization failure"];
        return;
    }
    if(!startDaemon()){
        [self.window close];
        self.window=nil;
        [self fatalWithText:@"Unable to start daemon or comm error"];
        return;
    }
    if(!AXIsProcessTrusted()){
        [self.window close];
        self.window=nil;
        [self fatalWithText:@"Can't acquire Accessibility Permissions"];
        return;
    }
    cgevFPCD=CGEventCreateKeyboardEvent(nil,kVK_Control,true);
    cgevFPCU=CGEventCreateKeyboardEvent(nil,kVK_Control,false);
    if(!cgevFPCD||!cgevFPCU){
        if(cgevFPCD)CFRelease(cgevFPCD);
        if(cgevFPCU)CFRelease(cgevFPCU);
        [self.window close];
        self.window=nil;
        [self fatalWithText:@"Can't create CGEvents"];
        return;
    }
    initializeHID();
    if(!devKeyboard||!elemKeyboardLedCapslock){
        [self.window close];
        self.window=nil;
        [self fatalWithText:@"Error initializing HID"];
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
    if(gopts&DOPT_AIRPORTEXTRA_ALT)interest|=NSLeftMouseDownMask;
    if(gopts&DOPT_POWER_LOCKSCREEN)interest|=NSSystemDefinedMask;
    
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
