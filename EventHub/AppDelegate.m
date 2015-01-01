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

bool doptDisableAllFiltering=true;

bool optFilterWordByWord;
bool optFilterCapslock;
//bool optFilterDelete;

bool smallHalt;CGEventFlags cachedEvFlags;
-(void)unhalt{smallHalt=false;}
static inline CGEventFlags ugcFlags(CGEventRef event){
    CGEventFlags f=CGEventGetFlags(event);
    f&=NSDeviceIndependentModifierFlagsMask;
    f&=~(kCGEventFlagMaskAlphaShift|kCGEventFlagMaskSecondaryFn);
    return f;
}
#define cc(errormsg,axerror) if(axerror){NSLog(@"%s: %d at %s(line %d)",errormsg,axerror,__PRETTY_FUNCTION__,__LINE__);AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert);break;}
// dopt used for PendingTextInputOperations
AXUIElementRef doptPTIOe;NSUInteger doptPTIOl,doptPTIOr;
CFTypeRef kAXTextInputMarkedRangeAttribute=@"AXTextInputMarkedRange";
-(void)delayedOperationOnAXT{
    do{
        cc("orphant delayedOperationOnAXT",!doptPTIOe);
        CFTypeRef axrange;NSRange range;
        cc("get AXTIMRA",AXUIElementCopyAttributeValue(doptPTIOe,kAXTextInputMarkedRangeAttribute,&axrange));
        cc("error translating AXValue",!AXValueGetValue(axrange,kAXValueCFRangeType,&range));
        cc("TextIMR not clean",(int)range.length|(int)(range.length>>32));
        cc("get AXSTRA",AXUIElementCopyAttributeValue(doptPTIOe,kAXSelectedTextRangeAttribute,&axrange));
        cc("error translating AXValue",!AXValueGetValue(axrange,kAXValueCFRangeType,&range));
        cc("TextSRA not clean",(int)range.length|(int)(range.length>>32));
        CFTypeRef axtext;cc("unable to get AXVA",AXUIElementCopyAttributeValue(doptPTIOe,kAXValueAttribute,&axtext));
        NSString*text=(__bridge NSString*)axtext;
        NSUInteger len=[text length]-doptPTIOr-1;
        unichar opcode=[text characterAtIndex:len];
        len-=doptPTIOl;
        if(len<2||len>4)break;
        range=NSMakeRange(doptPTIOl,len+1);
        axrange=AXValueCreate(kAXValueCFRangeType,&range);
        if(opcode==']'){
            doptPTIOl+=len;
            doptPTIOl-=(len=(len>>1)+(len&1));
        }else if(opcode=='[')len=(len>>1)+(len&1);
        else cc("unknown opcode",(opcode!='[')&&(opcode=']')&&opcode);
        range=NSMakeRange(doptPTIOl,len);
        text=[text substringWithRange:range];
        cc("set AXSTRA",AXUIElementSetAttributeValue(doptPTIOe,kAXSelectedTextRangeAttribute,axrange));
        cc("set AXSTA",AXUIElementSetAttributeValue(doptPTIOe,kAXSelectedTextAttribute,(__bridge CFTypeRef)text));
    }while(false);
    doptPTIOe=nil;
}
CGEventRef eventCallback(CGEventTapProxy proxy,CGEventType type,CGEventRef event,AppDelegate*self){
    if(doptDisableAllFiltering)return event;
    
    if(optFilterWordByWord)do{
        if(type!=kCGEventKeyDown)break;
        if(doptPTIOe){
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(delayedOperationOnAXT)object:nil];
            doptPTIOe=nil;cc("colliding delayedOperationOnAXT",1);
        }
        int64_t keycode=CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
        if(keycode!=kVK_ANSI_LeftBracket&&keycode!=kVK_ANSI_RightBracket)break;
        CGEventFlags f=ugcFlags(event);
        if(f)break; // if any modifier is down
        CFTypeRef elem=AXUIElementCreateSystemWide();
        cc("get AXFUIEA",AXUIElementCopyAttributeValue(elem,kAXFocusedUIElementAttribute,&elem));
        CFTypeRef role;cc("get AXRA",AXUIElementCopyAttributeValue(elem,kAXRoleAttribute,&role));
        if(!CFEqual(kAXTextFieldRole,role)&&!CFEqual(kAXTextAreaRole,role))break;
        CFTypeRef axrange;cc("get AXTIMRA",AXUIElementCopyAttributeValue(elem,kAXTextInputMarkedRangeAttribute,&axrange));
        NSRange range;cc("error translating AXValue",!AXValueGetValue(axrange,kAXValueCFRangeType,&range));
        if(!range.length)break;// not using input method
        CFTypeRef length;cc("get AXNCA",AXUIElementCopyAttributeValue(elem,kAXNumberOfCharactersAttribute,&length));
        doptPTIOl=range.location;doptPTIOr=[(__bridge NSNumber*)length unsignedIntegerValue]-range.location-range.length;
        doptPTIOe=elem;[self performSelector:@selector(delayedOperationOnAXT)withObject:nil afterDelay:0.1];
    }while(false);
    
    if(optFilterCapslock){
        if(type==kCGEventKeyDown||type==kCGEventKeyUp){
            CGEventFlags f=CGEventGetFlags(event);
            f&=~kCGEventFlagMaskAlphaShift;
            CGEventSetFlags(event,f);
        }else if(type==kCGEventFlagsChanged)do{
            if(smallHalt)break;
            CGEventFlags newFlags=CGEventGetFlags(event);
            CGEventFlags diff=cachedEvFlags^newFlags;
            // do not interfere with Shift!
            // it may interrupt typing:
            // aaa[SHIFT_DN]BBB[SHIFT_UP]ccc
            if((diff&kCGEventFlagMaskAlphaShift)&&!(newFlags&kCGEventFlagMaskAlphaShift)){
                NSLog(@"remit Capslock event");
                [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(unhalt)object:self];
                smallHalt=true;
                // since we are a active listener
                // CGEventPost will get queued instead of send immediately
                // so we do CGEventPost first instead of last
                CGEventPost(kCGSessionEventTap,event); // this is sq 2
                CGEventSetFlags(event,newFlags^kCGEventFlagMaskAlphaShift);// this is sq 1
                [self performSelector:@selector(unhalt)withObject:self];
            }cachedEvFlags=newFlags;
        }while(false);
    }
    
    // I'll live with CMD-BKSP/DELE(delete to line start/end) for now
    // use SHIFT-BKSP/DELE to replace it is impractical
    // (have to consider more compatibility and implement more logic)
    // may be later implement the following feature:
    // CMD-DELE               delete to line end
    // ALT-SHIFT-BKSP/DELE    delete whole word under cursor
//    if(optFilterDelete)do{
//        // should be event keyChar
//        if(type!=kCGEventKeyDown&&type!=kCGEventKeyUp)break;
////        int64_t isRepeat=CGEventGetIntegerValueField(event,kCGKeyboardEventAutorepeat);
//        int64_t keycode=CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode);
//        if(keycode!=kVK_Delete&&keycode!=kVK_ForwardDelete)break;
//        CGEventFlags f=ugcFlags(event);
//        if(f!=kCGEventFlagMaskShift)break;
//        CFTypeRef elem=AXUIElementCreateSystemWide();
//        if(AXUIElementCopyAttributeValue(elem,kAXFocusedUIElementAttribute,&elem))break;
//        CFTypeRef role;if(AXUIElementCopyAttributeValue(elem,kAXRoleAttribute,&role))break;
//        if(!CFEqual(kAXTextFieldRole,role)/*&&!CFEqual(kAXTextAreaRole,role)*/)break;
//        do{
//            // !!! for AXTextField(capable of multiple selection)
//            // !!! beware of some selection is on the same line
//            // !!! aaa [bbb] cc[c] like this, when delete
//            CFTypeRef axrange;if(AXUIElementCopyAttributeValue(elem,kAXSelectedTextRangeAttribute,&axrange))break;
//            CFTypeRef text;if(AXUIElementCopyAttributeValue(elem,kAXValueAttribute,&text))break;
//            CFRange range;if(!AXValueGetValue(axrange,kAXValueCFRangeType,&range))break;
//            if(keycode==kVK_ForwardDelete){
//                CFTypeRef len;if(AXUIElementCopyAttributeValue(elem,kAXNumberOfCharactersAttribute,&len))break;
//                range.length=[(__bridge NSNumber*)len longValue]-range.location;
//            }else if(keycode==kVK_Delete){
//                range.length+=range.location;
//                range.location=0;
//            }else break;
//            axrange=AXValueCreate(kAXValueCFRangeType,&range);
//            if(AXUIElementSetAttributeValue(elem,kAXSelectedTextRangeAttribute,axrange))break;
//            if(AXUIElementSetAttributeValue(elem,kAXSelectedTextAttribute,@""))break;
//            return nil;
//        }while(false);
//        AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert);
//    }while(false);

    return event;
}
-(void)someotherAppGotActivated:(NSNotification*)notification{
    NSDictionary*_n=[notification userInfo];if(!_n)return;
    NSRunningApplication*ra=[_n objectForKey:NSWorkspaceApplicationKey];if(!ra)return;
    NSString*name=[ra localizedName];
    bool cache=doptDisableAllFiltering;
    doptDisableAllFiltering=self.options[name];
    if(cache&&!doptDisableAllFiltering)
        cachedEvFlags=[NSEvent modifierFlags];
//    NSLog(@"%@ %d",name,doptDisableAllFiltering);
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
//    if(optFilterDelete)interest|=CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp);
    
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
    // don't move this line, it's also used in
    // -(void)someotherAppGotActivated:(NSNotification*)notification
    // to update cachedEvFlags
    doptDisableAllFiltering=true;
    if(self.eventTap){
        CFRelease(self.eventTap);
        self.eventTap=nil;
    }
    // TODO add settings panel instead of hard-code options
    self.options=[NSMutableDictionary new];
    id opt=(__bridge id)kCFBooleanTrue;
    self.options[@"Remote Desktop Connection"]=opt;
    self.options[@"VMware Fusion"]=opt;

    optFilterWordByWord=true;
    optFilterCapslock=true;
//    optFilterDelete=true;
}
@end
