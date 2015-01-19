//
//  main.m
//  EventHub
//
//  Created by revin on Dec.29,2014.
//  Copyright (c) 2014 revin. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "ProtocolCodes.h"

pid_t pidOfLoginProcess;
static inline int suspendLoginProcess(){
    if(pidOfLoginProcess<=0)return -1;
    return kill(pidOfLoginProcess,SIGSTOP);
}
static inline int resumeLoginProcess(){
    if(pidOfLoginProcess<=0)return -1;
    return kill(pidOfLoginProcess,SIGCONT);
}
int main(int argc,const char*argv[]){
    bool daemon=false;
    for(int i=0;i<argc;++i){
        if(!strcmp("-daemon",argv[i])){
            daemon=true;
            break;
        }
    }
    if(!daemon)return NSApplicationMain(argc,argv);
    // daemon code
    if(geteuid()){NSLog(@"fatal: daemon is not running as root, exit now");exit(8);}
    resumeLoginProcess();
    pid_t parent=0;
    if(1!=fread(&parent,sizeof(parent),1,stdin)||parent!=getppid()){NSLog(@"fatal: daemon handshake failure: %d(PPID) against %d",getppid(),parent);exit(8);}
    pid_t mypid=getpid();
    if(1!=fwrite(&mypid,sizeof(mypid),1,stdout)){NSLog(@"fatal: daemon handshake failure: send pid %d",mypid);exit(8);}
    uint32_t transcationSerial=1;
    while(true){
        uint32_t commbuffer[2];int retv=-1;
        if(1!=fread(&commbuffer,sizeof(commbuffer),1,stdin)){
            resumeLoginProcess();
            NSLog(@"IOError: reading comm");
            exit(5);
        }
        NSLog(@"->daemon %8d: %d",commbuffer[0],commbuffer[1]);
        if(commbuffer[0]!=transcationSerial){
            resumeLoginProcess();
            NSLog(@"IOError: transcation not match: %d(TRAS) %d(COMM)",transcationSerial,commbuffer[0]);
            exit(5);
        }
        switch(commbuffer[1]){
            case PROTO_SHUTDOWN_DAEMON:
                NSLog(@"daemon shutdown...");
                return 0;
            case PROTO_VALIDATE_LOGINWINDOW:{
                    NSArray*apps=[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.loginwindow"];
                    if([apps count]==1)
                        retv=pidOfLoginProcess=[[apps objectAtIndex:0]processIdentifier];
                    else pidOfLoginProcess=-1;
                }break;
            case PROTO_SUSPEND_LOGINWINDOW:
                retv=suspendLoginProcess();
                break;
            case PROTO_RESUME_LOGINWINDOW:
                retv=resumeLoginProcess();
                break;
            default:
                resumeLoginProcess();
                NSLog(@"daemon: unknown code %d",commbuffer[1]);
                exit(6);
        }
        ++transcationSerial;
        commbuffer[1]=retv;
        NSLog(@"<-daemon %8d: %d",commbuffer[0],commbuffer[1]);
        if(1!=fwrite(&commbuffer,sizeof(commbuffer),1,stdout)){
            resumeLoginProcess();
            NSLog(@"IOError: writing comm");
            exit(7);
        }
    }
}
