// This file is distributed under a BSD license. See LICENSE.txt for details.

// macOS system layer for the kkrieger player (replaces _start.cpp).
//
// Window and input use AppKit, sound is in sound_mac.mm. Files, time, fonts
// (CoreText instead of GDI), textures (converted to 8 bit exactly like the
// D3D version), geometry buffers and material setups are implemented here.
// Drawing is not implemented yet: calls are accepted and counted.
//
//   kkrieger file.kx [--fullscreen] [--headless] [--frames n]
//                    [--press-enter] [--dump-textures dir]

#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#include "_types.hpp"
#include "_start.hpp"
#include "_startdx.hpp"
#include "macos/fileio_mac.hpp"

/****************************************************************************/
/***                                                                      ***/
/***   Globals (the same as in _start.cpp)                                ***/
/***                                                                      ***/
/****************************************************************************/

sSystem_ *sSystem;
class sBroker_ *sBroker;
sInt sFatality;
sBool IntroStereo3D = sFALSE;
sInt IntroTargetAspect = 0;           // index into aspectRatios[] in mainplayer.cpp (4:3)
sInt IntroLoop = 0;

static const sInt IntroScreenX = 800;
static const sInt IntroScreenY = 600;

static sChar *CmdLineFile = (sChar *)"";
static const char *DumpDir = 0;
static sInt FrameCount = 0;                 // 0: run until quit
static sBool PressEnter = sFALSE;           // test: press enter every 0.5 s
static sBool Headless = sFALSE;             // test: no window, no sound
static sBool Fullscreen = sFALSE;
static sBool Quit = sFALSE;
static NSWindow *Window;
static sBool MouseCaptured = sFALSE;
static sF64 MouseDX,MouseDY;                // accumulated relative mouse motion

void MacSoundInit();
void MacSoundExit();
static sU64 StartTimeNs;

// per-texture data that does not fit into sHardTex (which has a D3D pointer)
struct MacTexture
{
  sU32 *Level0;                   // 8 bit texels of the top mip level, D3D byte order
  sInt Generation;                // incremented for each upload
};
static MacTexture MacTextures[MAX_TEXTURE];

// geometry: every handle owns its own memory
struct MacGeo
{
  sU8 *Vertex;
  sInt VertexAlloc;
  sU8 *Index;
  sInt IndexAlloc;
  sInt Dirty;                     // sGEO_VERTEX/sGEO_INDEX: must be uploaded again
};
static MacGeo MacGeos[MAX_GEOHANDLE];

static const sInt FVFSize[] = { 0,32,32,64,16,16,32,48 };  // see sFVF_??? in _start.hpp

static sInt DrawCalls;
static sInt StateChanges;

/****************************************************************************/
/***                                                                      ***/
/***   Startup and main loop                                              ***/
/***                                                                      ***/
/****************************************************************************/

static void ParseArgs(int argc,char **argv)
{
  for(int i=1;i<argc;i++)
  {
    if(!strcmp(argv[i],"--dump-textures") && i+1<argc)
      DumpDir = argv[++i];
    else if(!strcmp(argv[i],"--press-enter"))
      PressEnter = sTRUE;
    else if(!strcmp(argv[i],"--headless"))
      Headless = sTRUE;
    else if(!strcmp(argv[i],"--fullscreen"))
      Fullscreen = sTRUE;
    else if(!strcmp(argv[i],"--frames") && i+1<argc)
      FrameCount = atoi(argv[++i]);
    else if(argv[i][0]!='-')
      CmdLineFile = argv[i];
  }
}

int main(int argc,char **argv)
{
  @autoreleasepool
  {
    ParseArgs(argc,argv);
    StartTimeNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

    sSystem = new sSystem_;
    sSetMem(sSystem,0,sizeof(sSystem_));
    sSystem->InitX();
  }
  return 0;
}

static void DumpTextures()
{
  sInt live = 0, bytes = 0;
  for(sInt i=0;i<MAX_TEXTURE;i++)
  {
    if(sSystem->Textures[i].Flags)
    {
      live++;
      bytes += sSystem->Textures[i].XSize*sSystem->Textures[i].YSize*4;
    }
  }
  fprintf(stderr,"textures: %d alive, %d KB (top level)\n",live,bytes/1024);

  {
    mkdir(DumpDir,0755);
    sInt n = 0;
    for(sInt i=0;i<MAX_TEXTURE;i++)
    {
      sHardTex *tex = &sSystem->Textures[i];
      if(!tex->Flags || !MacTextures[i].Level0)
        continue;
      char name[1024];
      snprintf(name,sizeof(name),"%s/tex%03d_%dx%d.tga",DumpDir,i,tex->XSize,tex->YSize);
      sU8 header[18] = {0};
      header[2] = 2;                                  // uncompressed true color
      header[12] = tex->XSize & 255; header[13] = tex->XSize >> 8;
      header[14] = tex->YSize & 255; header[15] = tex->YSize >> 8;
      header[16] = 32;
      header[17] = 0x28;                              // top-down, 8 alpha bits
      FILE *f = fopen(name,"wb");
      if(f)
      {
        fwrite(header,1,18,f);
        fwrite(MacTextures[i].Level0,4,tex->XSize*tex->YSize,f);
        fclose(f);
        n++;
      }
    }
    fprintf(stderr,"dumped %d textures to %s\n",n,DumpDir);
  }
}

/****************************************************************************/

// macOS virtual key codes (kVK_*) to the codes of the Windows version:
// letters and digits as 'A'..'Z' / '0'..'9', some keys as sKEY_*.
static sInt MapKey(unsigned short kc)
{
  static const char letters[0x30] =             // kVK_ANSI_* 0x00..0x2f
  {
    'A','S','D','F','H','G','Z','X','C','V', 0 ,'B','Q','W','E','R',
    'Y','T','1','2','3','4','6','5', 0 ,'9','7', 0 ,'8','0', 0 ,'O',
    'U', 0 ,'I','P', 0 ,'L','J', 0 ,'K', 0 , 0 , 0 , 0 ,'N','M', 0 ,
  };
  switch(kc)
  {
  case 0x24: case 0x4c: return sKEY_ENTER;      // return, keypad enter
  case 0x35: return sKEY_ESCAPE;
  case 0x31: return sKEY_SPACE;
  case 0x30: return sKEY_TAB;
  case 0x33: return sKEY_BACKSPACE;
  case 0x7b: return sKEY_LEFT;
  case 0x7c: return sKEY_RIGHT;
  case 0x7d: return sKEY_DOWN;
  case 0x7e: return sKEY_UP;
  }
  return kc<0x30 ? letters[kc] : 0;
}

static void AddKey(sU32 key)
{
  if(sSystem->KeyIndex < MAX_KEYBUFFER)
    sSystem->KeyBuffer[sSystem->KeyIndex++] = key;
}

static void CaptureMouse(sBool on)
{
  if(on==MouseCaptured || Headless)
    return;
  MouseCaptured = on;
  CGAssociateMouseAndMouseCursorPosition(on ? false : true);
  if(on) [NSCursor hide]; else [NSCursor unhide];
}

// handle all pending events, like the message pump of the Windows version
static void PumpEvents()
{
  if(Headless)
    return;
  @autoreleasepool
  {
    NSEvent *ev;
    while((ev = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES]))
    {
      switch(ev.type)
      {
      case NSEventTypeKeyDown:
      case NSEventTypeKeyUp:
        if(ev.modifierFlags & NSEventModifierFlagCommand)
          break;                            // menu shortcuts (cmd-q, cmd-f)
        if(sInt key = MapKey(ev.keyCode))
          AddKey(ev.type==NSEventTypeKeyUp ? key|sKEYQ_BREAK : key);
        continue;                           // keys are ours: no system beep
      case NSEventTypeLeftMouseDown:
        if(!MouseCaptured && ev.window==Window)
        {
          CaptureMouse(sTRUE);              // the first click only captures the mouse
          break;
        }
        sSystem->MouseButtons |= 1;
        AddKey(sKEY_MOUSEL);
        break;
      case NSEventTypeLeftMouseUp:
        if(sSystem->MouseButtons & 1)
        {
          sSystem->MouseButtons &= ~1;
          AddKey(sKEY_MOUSEL|sKEYQ_BREAK);
        }
        break;
      case NSEventTypeMouseMoved:
      case NSEventTypeLeftMouseDragged:
      case NSEventTypeRightMouseDragged:
        if(MouseCaptured)
        {
          MouseDX += ev.deltaX;
          MouseDY += ev.deltaY;
        }
        break;
      default:
        break;
      }
      [NSApp sendEvent:ev];
    }
  }
}

@interface KKAppDelegate : NSObject <NSApplicationDelegate,NSWindowDelegate>
@end
@implementation KKAppDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app { Quit = sTRUE; return NSTerminateCancel; }
- (BOOL)windowShouldClose:(NSWindow *)sender { Quit = sTRUE; return NO; }
- (void)windowDidResignKey:(NSNotification *)n { CaptureMouse(sFALSE); }
@end

static void CreateAppWindow()
{
  static KKAppDelegate *delegate;

  [NSApplication sharedApplication];
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
  delegate = [KKAppDelegate new];
  NSApp.delegate = delegate;

  NSMenu *bar = [NSMenu new];
  NSMenuItem *appItem = [NSMenuItem new];
  [bar addItem:appItem];
  NSMenu *appMenu = [NSMenu new];
  [appMenu addItemWithTitle:@"Toggle Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
  [appMenu addItemWithTitle:@"Quit .kkrieger" action:@selector(terminate:) keyEquivalent:@"q"];
  appItem.submenu = appMenu;
  NSApp.mainMenu = bar;

  NSRect r = NSMakeRect(0,0,sSystem->ConfigX,sSystem->ConfigY);
  Window = [[NSWindow alloc] initWithContentRect:r
    styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
    backing:NSBackingStoreBuffered defer:NO];
  Window.title = @".kkrieger";
  Window.contentAspectRatio = r.size;
  Window.acceptsMouseMovedEvents = YES;
  Window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
  Window.delegate = delegate;
  NSView *view = [[NSView alloc] initWithFrame:r];
  view.wantsLayer = YES;
  view.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
  Window.contentView = view;
  [Window center];
  [Window makeKeyAndOrderFront:nil];
  [NSApp finishLaunching];
  [NSApp activateIgnoringOtherApps:YES];
  if(Fullscreen)
    [Window toggleFullScreen:nil];
  PumpEvents();
}

void sSystem_::InitX()
{
  ConfigFlags = sSF_DIRECT3D;
  ConfigX = IntroScreenX;
  ConfigY = IntroScreenY;
  sSetRndSeed(GetTime()&0x7fffffff);

  WScreenCount = 1;
  for(sInt i=0;i<MAX_TEXTURE;i++)
    Textures[i].Flags = 0;
  MtrlClearCaches();
  InitScreens();

  if(!sAppHandler(sAPPCODE_CONFIG,0))
    return;

  if(!Headless)
    CreateAppWindow();

  sInt t0 = GetTime();
  sAppHandler(sAPPCODE_INIT,0);
  fprintf(stderr,"init: %d ms\n",GetTime()-t0);

  if(!Headless)
    MacSoundInit();

  sInt lastFrameTime = GetTime();
  for(sInt f=0;!Quit && (FrameCount<=0 || f<FrameCount);f++)
  {
    PumpEvents();
    if(PressEnter)
    {
      if(f%30==0)  AddKey(sKEY_ENTER);
      if(f%30==5)  AddKey(sKEY_ENTER|sKEYQ_BREAK);
    }
    for(sInt i=0;i<KeyIndex;i++)
      sAppHandler(sAPPCODE_KEY,KeyBuffer[i]);
    KeyIndex = 0;

    DrawCalls = 0;
    StateChanges = 0;
    Render();
    if(Headless && (!PressEnter || f%60==0))
      fprintf(stderr,"frame %d: %d draw calls, %d state changes\n",f,DrawCalls,StateChanges);

    // ~60 fps until the renderer paces frames with the display
    if(!Headless || PressEnter)
    {
      sInt wait = lastFrameTime + 16 - GetTime();
      if(wait>0) usleep(wait*1000);
      lastFrameTime = GetTime();
    }
  }

  if(!Headless)
  {
    CaptureMouse(sFALSE);
    MacSoundExit();
  }

  if(DumpDir)
    DumpTextures();
}

void sSystem_::InitScreens()
{
  Screen[0].XSize = ConfigX;
  Screen[0].YSize = ConfigY;
  ViewportX = ConfigX;
  ViewportY = ConfigY;
}

void sSystem_::Render()
{
  LastCamera.Init();
  LastMatrix.Init();
  LastViewProject.Init();

  sAppHandler(sAPPCODE_FRAME,0);
  sAppHandler(sAPPCODE_PAINT,0);
}

void sSystem_::Exit()
{
  Quit = sTRUE;
}

/*sNORETURN*/ void sSystem_::Abort(sChar *msg)
{
  if(msg)
    fprintf(stderr,"fatal error: %s\n",msg);
  exit(1);
}

void sSystem_::Log(sChar *s)
{
  if(!sFatality)
    fputs(s,stderr);
}

sChar *sSystem_::GetCmdLine()
{
  return CmdLineFile;
}

sInt sSystem_::GetTime()
{
  return (sInt)((clock_gettime_nsec_np(CLOCK_UPTIME_RAW)-StartTimeNs)/1000000);
}

void sSystem_::Progress(sInt done,sInt max)
{
  static sInt lasttime;
  sInt time = GetTime();
  if(time > lasttime+450 || done==max)
  {
    lasttime = time;
    if(Headless)
      fprintf(stderr,"progress: %d/%d\n",done,max);
    PumpEvents();
    if(Quit)
      exit(0);
  }
}

void sSystem_::WaitForKey()
{
}

/****************************************************************************/
/***                                                                      ***/
/***   Files                                                              ***/
/***                                                                      ***/
/****************************************************************************/

sU8 *sSystem_::LoadFile(const sChar *name,sInt &size)
{
  return sMacLoadFile(name,size);
}

sU8 *sSystem_::LoadFile(const sChar *name)
{
  sInt dummy;
  return sMacLoadFile(name,dummy);
}

/****************************************************************************/

// the Windows version moved the cursor back to the window center on every
// call and returned the accumulated motion as an absolute position
void sSystem_::GetInput(sInt id,sInputData &data)
{
  static sF64 x,y;
  CaptureMouse(Window.isKeyWindow);
  x += MouseDX;
  y += MouseDY;
  MouseDX = MouseDY = 0;
  sSetMem(&data,0,sizeof(data));
  data.Type = sIDT_MOUSE;
  data.AnalogCount = 3;
  data.DigitalCount = 3;
  data.Analog[0] = (sInt) x;
  data.Analog[1] = (sInt) y;
  data.Digital = MouseButtons;
}

/****************************************************************************/
/***                                                                      ***/
/***   Fonts (CoreText instead of GDI)                                    ***/
/***                                                                      ***/
/****************************************************************************/

static CGContextRef FontContext;
static CTFontRef FontRef;
static sF32 FontAscent;

// GDI's CreateFont(-height,width,...): em size = height, average character
// width = width (0: natural). The average width comes from the OS/2 table.
static CTFontRef MakeFont(const sChar *name,sInt width,sInt height,sInt style)
{
  CFStringRef family = CFStringCreateWithCString(0,name[0] ? name : "Arial",kCFStringEncodingWindowsLatin1);
  CTFontRef font = CTFontCreateWithName(family,height,0);
  CFStringRef got = CTFontCopyFamilyName(font);
  if(CFStringCompare(got,family,kCFCompareCaseInsensitive)!=kCFCompareEqualTo)
  {
    // CTFontCreateWithName wants exact names; match the family case-insensitively
    CFArrayRef families = CTFontManagerCopyAvailableFontFamilyNames();
    for(CFIndex i=0;i<CFArrayGetCount(families);i++)
    {
      CFStringRef f = (CFStringRef)CFArrayGetValueAtIndex(families,i);
      if(CFStringCompare(f,family,kCFCompareCaseInsensitive)==kCFCompareEqualTo)
      {
        CFRelease(font);
        font = CTFontCreateWithName(f,height,0);
        break;
      }
    }
    CFRelease(families);
  }
  CFRelease(got);
  CFRelease(family);

  CTFontSymbolicTraits traits = 0;
  if(style & 2) traits |= kCTFontBoldTrait;
  if(style & 1) traits |= kCTFontItalicTrait;
  if(traits)
  {
    CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(font,height,0,traits,traits);
    if(styled) { CFRelease(font); font = styled; }
  }

  if(width>0)
  {
    sF32 avg = 0;
    CFDataRef os2 = CTFontCopyTable(font,kCTFontTableOS2,0);
    if(os2 && CFDataGetLength(os2)>=4)
    {
      const sU8 *p = CFDataGetBytePtr(os2);
      avg = (sS16)((p[2]<<8)|p[3]) * height / (sF32)CTFontGetUnitsPerEm(font);
    }
    if(os2) CFRelease(os2);
    if(avg>0)
    {
      CGAffineTransform m = CGAffineTransformMakeScale(width/avg,1);
      CTFontRef scaled = CTFontCreateCopyWithAttributes(font,height,&m,0);
      CFRelease(font);
      font = scaled;
    }
  }
  return font;
}

sInt sSystem_::FontBegin(sInt pagex,sInt pagey,const sChar *name,sInt xs,sInt ys,sInt style)
{
  FontMem = new sU32[pagex*pagey];
  sSetMem(FontMem,0,pagex*pagey*4);

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  FontContext = CGBitmapContextCreate(FontMem,pagex,pagey,8,pagex*4,cs,
    kCGImageAlphaNoneSkipFirst|kCGBitmapByteOrder32Little);   // = GDI's 32 bit DIB (0x00rrggbb)
  CGColorSpaceRelease(cs);

  // GDI coordinates: origin top left, y down
  CGContextTranslateCTM(FontContext,0,pagey);
  CGContextScaleCTM(FontContext,1,-1);
  CGContextSetTextMatrix(FontContext,CGAffineTransformMakeScale(1,-1));
  CGContextSetShouldSmoothFonts(FontContext,false);
  CGContextSetRGBFillColor(FontContext,1,1,1,1);

  FontRef = MakeFont(name,xs,ys,style);
  FontAscent = CTFontGetAscent(FontRef);
  return (sInt)(sFRound(CTFontGetAscent(FontRef))+sFRound(CTFontGetDescent(FontRef)));
}

static CTLineRef MakeLine(const sChar *string,sInt len)
{
  if(len==-1)
    len = sGetStringLen(string);
  CFStringRef str = CFStringCreateWithBytes(0,(const UInt8 *)string,len,kCFStringEncodingWindowsLatin1,false);
  CFStringRef keys[] = { kCTFontAttributeName, kCTForegroundColorFromContextAttributeName };
  CFTypeRef values[] = { FontRef, kCFBooleanTrue };
  CFDictionaryRef attr = CFDictionaryCreate(0,(const void **)keys,(const void **)values,2,
    &kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  CFAttributedStringRef astr = CFAttributedStringCreate(0,str,attr);
  CTLineRef line = CTLineCreateWithAttributedString(astr);
  CFRelease(astr);
  CFRelease(attr);
  CFRelease(str);
  return line;
}

sInt sSystem_::FontWidth(const sChar *string,sInt len)
{
  CTLineRef line = MakeLine(string,len);
  sF32 w = CTLineGetTypographicBounds(line,0,0,0);
  CFRelease(line);
  return (sInt)sFRound(w);
}

void sSystem_::FontPrint(sInt x,sInt y,const sChar *string,sInt len)
{
  CTLineRef line = MakeLine(string,len);
  CGContextSetTextPosition(FontContext,x,y+FontAscent);   // GDI: y is the top of the cell
  CTLineDraw(line,FontContext);
  CFRelease(line);
}

void sSystem_::FontEnd()
{
  CGContextFlush(FontContext);
  CGContextRelease(FontContext);
  CFRelease(FontRef);
  FontContext = 0;
  FontRef = 0;
  delete[] FontMem;
  FontMem = 0;
}

/****************************************************************************/
/***                                                                      ***/
/***   Textures                                                           ***/
/***                                                                      ***/
/****************************************************************************/

// 16 bit per channel (B,G,R,A) to the 8 bit texel layout of the D3D version.
// mip levels are generated the same way, but only the top level is kept here.
static void ConvertTexture(sHardTex *tex,MacTexture *mt,const sU16 *source)
{
  sInt xs = tex->XSize, ys = tex->YSize;
  delete[] mt->Level0;
  mt->Level0 = new sU32[xs*ys];
  sU32 *d = mt->Level0;
  const sU16 *s16 = source;

  for(sInt i=0;i<xs*ys;i++)
  {
    if(tex->Format==sTF_Q8W8V8U8)
    {
      d[i] = (((((sInt)s16[2]-0x4000)>>7)&0xff)    ) |
             (((((sInt)s16[1]-0x4000)>>7)&0xff)<< 8) |
             (((((sInt)s16[0]-0x4000)>>7)&0xff)<<16) |
             (((((sInt)s16[3]-0x4000)>>7)&0xff)<<24);
    }
    else
    {
      d[i] = (((s16[0]>>7)&0xff)    ) |
             (((s16[1]>>7)&0xff)<< 8) |
             (((s16[2]>>7)&0xff)<<16) |
             (((s16[3]>>7)&0xff)<<24);
    }
    s16 += 4;
  }
  mt->Generation++;
}

sInt sSystem_::AddTexture(sInt xs,sInt ys,sInt format,sU16 *data,sInt mipcount,sInt miptresh)
{
  sVERIFY(format>0 && format<sTF_MAX);

  for(sInt i=0;i<MAX_TEXTURE;i++)
  {
    sHardTex *tex = &Textures[i];
    if(tex->Flags==0)
    {
      mipcount = sMin(mipcount,sGetPower2(xs));
      mipcount = sMin(mipcount,sGetPower2(ys));
      if(xs & (xs-1) || ys & (ys-1))
        mipcount = 1;

      tex->RefCount = 1;
      tex->XSize = xs;
      tex->YSize = ys;
      tex->Flags = sTIF_ALLOCATED;
      tex->Format = format;
      tex->MipLevels = mipcount;
      tex->Tex = 0;

      if(data==0)
      {
        if(tex->XSize==0)
        {
          tex->XSize = Screen[0].XSize;
          tex->YSize = Screen[0].YSize;
        }
        tex->Flags |= sTIF_RENDERTARGET;
      }
      else
        ConvertTexture(tex,&MacTextures[i],data);
      return i;
    }
  }
  return sINVALID;
}

void sSystem_::AddRefTexture(sInt handle)
{
  if(handle!=sINVALID)
  {
    sVERIFY(handle>=0 && handle<MAX_TEXTURE);
    sVERIFY(Textures[handle].RefCount>0);
    Textures[handle].RefCount++;
  }
}

void sSystem_::RemTexture(sInt handle)
{
  if(handle!=sINVALID)
  {
    sVERIFY(handle>=0 && handle<MAX_TEXTURE);
    sHardTex *tex = &Textures[handle];
    sVERIFY(tex->RefCount>=1);
    if(--tex->RefCount==0)
    {
      delete[] MacTextures[handle].Level0;
      MacTextures[handle].Level0 = 0;
      tex->Flags = 0;
      tex->Tex = 0;
    }
  }
}

void sSystem_::GetTextureSize(sInt handle,sInt &w,sInt &h)
{
  if(handle != sINVALID)
  {
    sVERIFY(handle>=0 && handle<MAX_TEXTURE);
    w = Textures[handle].XSize;
    h = Textures[handle].YSize;
  }
}

void sSystem_::GrabScreen(sInt sourceRT,const sRect &win,sInt tex,sBool stretch)
{
}

/****************************************************************************/
/***                                                                      ***/
/***   Viewport, transforms, render states                                ***/
/***                                                                      ***/
/****************************************************************************/

void sSystem_::Clear(sU32 flags,sU32 color)
{
}

void sSystem_::SetViewport(const sViewport &vp)
{
  sInt txs,tys;

  CurrentViewport = vp;
  if(vp.RenderTarget == sINVALID)
  {
    txs = Screen[vp.Screen].XSize;
    tys = Screen[vp.Screen].YSize;
  }
  else
  {
    sVERIFY(Textures[vp.RenderTarget].Flags & sTIF_RENDERTARGET);
    txs = Textures[vp.RenderTarget].XSize;
    tys = Textures[vp.RenderTarget].YSize;
  }

  if(!vp.Window.XSize() || !vp.Window.YSize())
    CurrentViewport.Window.Init(0,0,txs,tys);

  ViewportX = CurrentViewport.Window.XSize();
  ViewportY = CurrentViewport.Window.YSize();
}

void sSystem_::SetScissor(const sFRect *scissor)
{
}

void sSystem_::SetStates(sU32 *stream)
{
  while(*stream!=0xffffffff)
  {
    SetState(stream[0],stream[1]);
    stream += 2;
  }
}

void sSystem_::SetState(sU32 token,sU32 value)
{
  StateChanges++;
}

void sSystem_::SetViewProject(const sMaterialEnv *env)
{
  sVERIFY(env);

  env->MakeProjectionMatrix(LastProjection);
  LastCamera = env->CameraSpace;
  LastCamera.TransR();

  LastViewProject.Mul4(LastCamera,LastProjection);
}

void sSystem_::GetTransform(sInt mode,sMatrix &mat)
{
  switch(mode)
  {
  case sGT_VIEW:
    mat = LastCamera;
    break;
  case sGT_MODELVIEW:
    mat = LastMatrix;
    mat.TransR();
    mat.MulA(mat,LastCamera);
    break;
  case sGT_MODEL:
    mat = LastMatrix;
    break;
  case sGT_PROJECT:
    mat = LastProjection;
    break;
  default:
    mat.Init();
    break;
  }
}

/****************************************************************************/
/***                                                                      ***/
/***   Geometry                                                           ***/
/***                                                                      ***/
/****************************************************************************/

sInt sSystem_::GeoAdd(sInt fvf,sInt prim)
{
  sVERIFY(fvf>=1 && fvf<(sInt)sCOUNTOF(FVFSize));
  for(sInt i=1;i<MAX_GEOHANDLE;i++)
  {
    sGeoHandle *gh = &GeoHandle[i];
    if(gh->Mode==0)
    {
      sSetMem(gh,0,sizeof(*gh));
      gh->VertexSize = FVFSize[fvf];
      gh->FVF = fvf;
      gh->Mode = prim;
      MacGeos[i].Dirty = sGEO_VERTEX|sGEO_INDEX;
      return i;
    }
  }
  sFatal("GeoAdd() ran out of handles");
  return 0;
}

void sSystem_::GeoRem(sInt handle)
{
  sVERIFY(handle>=1 && handle<MAX_GEOHANDLE);
  sVERIFY(GeoHandle[handle].Mode!=0);
  MacGeo *mg = &MacGeos[handle];
  delete[] mg->Vertex;
  delete[] mg->Index;
  sSetMem(mg,0,sizeof(*mg));
  GeoHandle[handle].Mode = 0;
}

// dynamic buffers are "discarded" on request; static ones stay valid
void sSystem_::GeoFlush(sInt handle,sInt what)
{
  sVERIFY(handle>=1 && handle<MAX_GEOHANDLE);
  sGeoHandle *gh = &GeoHandle[handle];
  if((what & sGEO_VERTEX) && !(gh->Mode & sGEO_STATVB)) MacGeos[handle].Dirty |= sGEO_VERTEX;
  if((what & sGEO_INDEX) && !(gh->Mode & sGEO_STATIB))  MacGeos[handle].Dirty |= sGEO_INDEX;
}

sInt sSystem_::GeoDraw(sInt &handle)
{
  sVERIFY(handle>=1 && handle<MAX_GEOHANDLE);
  sVERIFY(GeoHandle[handle].Mode!=0);
  sGeoHandle *gh = &GeoHandle[handle];

  sInt update = MacGeos[handle].Dirty;
  if(gh->Vertex.Count == 0)
    update |= sGEO_VERTEX|sGEO_INDEX;
  if(update)
    return update;

  DrawCalls++;
  return 0;
}

static void GrowBuffer(sU8 *&mem,sInt &alloc,sInt size)
{
  if(size>alloc)
  {
    delete[] mem;
    alloc = sMax(size,alloc*2);
    mem = new sU8[alloc];
  }
}

void sSystem_::GeoBegin(sInt handle,sInt vc,sInt ic,sF32 **fp,void **ip,sInt upd)
{
  sVERIFY(handle>=1 && handle<MAX_GEOHANDLE);
  sVERIFY(GeoHandle[handle].Mode!=0);
  sGeoHandle *gh = &GeoHandle[handle];
  MacGeo *mg = &MacGeos[handle];

  if(fp) *fp = 0;
  if(ip) *ip = 0;

  if(upd & sGEO_VERTEX)
  {
    gh->Vertex.Start = 0;
    gh->Vertex.Count = vc;
    GrowBuffer(mg->Vertex,mg->VertexAlloc,vc*gh->VertexSize);
    if(fp) *fp = (sF32 *) mg->Vertex;
    gh->Locked |= sGEO_VERTEX;
    mg->Dirty &= ~sGEO_VERTEX;
  }
  if(upd & sGEO_INDEX)
  {
    gh->Index.Start = 0;
    gh->Index.Count = ic;
    if(ic)
    {
      GrowBuffer(mg->Index,mg->IndexAlloc,ic*((gh->Mode & sGEO_IND32B) ? 4 : 2));
      if(ip) *ip = mg->Index;
      gh->Locked |= sGEO_INDEX;
    }
    mg->Dirty &= ~sGEO_INDEX;
  }
}

void sSystem_::GeoEnd(sInt handle,sInt vc,sInt ic)
{
  sVERIFY(handle>=1 && handle<MAX_GEOHANDLE);
  sGeoHandle *gh = &GeoHandle[handle];
  gh->Locked = 0;
  if(vc!=-1) gh->Vertex.Count = vc;
  if(ic!=-1) gh->Index.Count = ic;
}

/****************************************************************************/
/***                                                                      ***/
/***   Material setups                                                    ***/
/***                                                                      ***/
/****************************************************************************/

static sInt ShaderLength(const sU32 *code)
{
  if(!code) return 0;
  sInt i = 0;
  while(code[i]!=0x0000ffff) i++;   // D3D end token
  return i+1;
}

sInt sSystem_::MtrlAddSetup(const sU32 *states,const sU32 *vs,const sU32 *ps)
{
  sInt stateLen;
  for(stateLen=0;states[stateLen] != ~0U;stateLen+=2);
  stateLen += 2;

  sInt id;
  for(id=0;id<MAX_SETUPS;id++)
    if(!Setups[id].RefCount)
      break;
  if(id==MAX_SETUPS)
    return sINVALID;

  sMaterialSetup *setup = &Setups[id];
  sInt vsLen = ShaderLength(vs), psLen = ShaderLength(ps);
  setup->RefCount = 1;
  setup->States = new sU32[stateLen];
  setup->VSCode = vsLen ? new sU32[vsLen] : 0;
  setup->PSCode = psLen ? new sU32[psLen] : 0;
  setup->VS = 0;
  setup->PS = 0;
  sCopyMem(setup->States,states,stateLen*4);
  if(vsLen) sCopyMem(setup->VSCode,vs,vsLen*4);
  if(psLen) sCopyMem(setup->PSCode,ps,psLen*4);
  return id;
}

void sMaterialSetup::Cleanup()
{
  delete[] States;
  delete[] VSCode;
  delete[] PSCode;
  States = VSCode = PSCode = 0;
}

void sSystem_::MtrlAddRefSetup(sInt sid)
{
  sVERIFY(sid >= 0 && sid < MAX_SETUPS);
  sVERIFY(Setups[sid].RefCount);
  Setups[sid].AddRef();
}

void sSystem_::MtrlRemSetup(sInt sid)
{
  sVERIFY(sid >= 0 && sid < MAX_SETUPS);
  sVERIFY(Setups[sid].RefCount);
  Setups[sid].Release();
}

void sSystem_::MtrlClearCaches()
{
  CurrentSetupId = sINVALID;
  for(sInt i=0;i<MAX_TEXSTAGE;i++)
    CurrentTextures[i] = sINVALID;
  for(sInt i=0;i<0x310;i++)
    CurrentStates[i] = 0xfefefefe;
}

void sSystem_::MtrlSetSetup(sInt sid)
{
  if(sid == CurrentSetupId)
    return;
  sVERIFY(sid >= 0 && sid < MAX_SETUPS);
  sMaterialSetup *setup = &Setups[sid];
  sVERIFY(setup->RefCount > 0);

  if(CurrentSetupId != sINVALID)
    Setups[CurrentSetupId].Release();
  setup->AddRef();

  for(sU32 *st = setup->States;st[0] != ~0U;st += 2)
  {
    sVERIFY(st[0] < 0x310);
    if(st[1] != CurrentStates[st[0]])
    {
      SetState(st[0],st[1]);
      CurrentStates[st[0]] = st[1];
    }
  }
  CurrentSetupId = sid;
}

void sSystem_::MtrlSetInstance(const sMaterialInstance &inst)
{
  for(sInt i=0;i<inst.NumTextures;i++)
    CurrentTextures[i] = inst.Textures[i];
}

/****************************************************************************/
/***                                                                      ***/
/***   Platform independent helpers (copied from _start.cpp)              ***/
/***                                                                      ***/
/****************************************************************************/

void sMaterialEnv::Init()
{
  sSetMem(this,0,sizeof(*this));

  ModelSpace.Init();
  CameraSpace.Init();
  NearClip = 0.125f;
  FarClip = 4096.0f;
  ZoomX = 1.0f;
  ZoomY = 1.0f;
  CenterX = 0.0f;
  CenterY = 0.0f;
  FogStart = 0;
  FogEnd = FarClip;
  FogColor = 0xff808080;
}

void sMaterialEnv::MakeProjectionMatrix(sMatrix &pmat) const
{
  sF32 q;
  sF32 shiftX = 1.0f / sSystem->ViewportX;
  sF32 shiftY = 1.0f / sSystem->ViewportY;

  switch(Orthogonal)
  {
  case sMEO_NORMALISED: // -1 .. 1
    pmat.i.Init(ZoomX                  ,0                       ,0 ,0);
    pmat.j.Init(0                      ,ZoomY                   ,0 ,0);
    pmat.k.Init(0                      ,0                       ,1.0f/FarClip,0);
    pmat.l.Init(-shiftX                ,shiftY                  ,0 ,1);
    break;

  case sMEO_PERSPECTIVE:
    q = 1.0f;
    pmat.i.Init(ZoomX         ,0               , 0              ,0);
    pmat.j.Init(0             ,ZoomY           , 0              ,0);
    pmat.k.Init(CenterX       ,CenterY         , q              ,1);
    pmat.l.Init(-shiftX       ,shiftY          ,-q*NearClip     ,0);
    break;
  }
}

sMaterial::~sMaterial()
{
}

void sViewport::Init(sInt screen)
{
  Screen = screen;
  RenderTarget = -1;
  Window.Init(0,0,sSystem->Screen[screen].XSize,sSystem->Screen[screen].YSize);
}

void sViewport::InitTex(sInt handle)
{
  Screen = -1;
  RenderTarget = handle;
  Window.x0 = 0;
  Window.y0 = 0;
  sSystem->GetTextureSize(handle,Window.x1,Window.y1);
}
