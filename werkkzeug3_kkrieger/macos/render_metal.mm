// This file is distributed under a BSD license. See LICENSE.txt for details.

// Metal renderer for the macOS player. Implements the graphics part of
// sSystem_ the way the Direct3D 9 version in _start.cpp does: a D3D render
// state array, material setups with D3D9 shader bytecode (translated to MSL
// by d3d9_msl.cpp), textures, render targets and geometry buffers.
//
// The game renders into an 800x600 back buffer (like the original), which is
// scaled into the window when the frame is presented.

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include <map>
#include <string>

#include "_types.hpp"
#include "_start.hpp"
#include "_startdx.hpp"
#include "macos/d3d9_msl.hpp"

/****************************************************************************/
/***                                                                      ***/
/***   State                                                              ***/
/***                                                                      ***/
/****************************************************************************/

static id<MTLDevice> Dev;
static id<MTLCommandQueue> Queue;
static CAMetalLayer *Layer;
static NSView *LayerView;
static id<MTLCommandBuffer> Cmd;
static id<MTLRenderCommandEncoder> Enc;
static sInt EncTarget = -1000;            // -1: back buffer, >=0: texture handle
static id<MTLTexture> BackColor,BackDepth;

static const int FramesInFlight = 3;
static const size_t RingSize = 32<<20;
static dispatch_semaphore_t FrameSem;
static id<MTLBuffer> Ring[FramesInFlight];
static int RingIndex;
static size_t RingPos;

struct MacTex
{
  id<MTLTexture> Tex;
  id<MTLTexture> Depth;           // render targets: own depth/stencil buffer
};
static MacTex MTex[MAX_TEXTURE];
static id<MTLTexture> CubeNormalizer,AttenVolume,Dummy2D,DummyCube,Dummy3D;

struct MacGeo
{
  sU8 *Vertex;
  sInt VertexAlloc;
  sU8 *Index;
  sInt IndexAlloc;
  sInt Dirty;                     // sGEO_VERTEX/sGEO_INDEX: must be uploaded again
  id<MTLBuffer> VB,IB;            // static buffers
};
static MacGeo MGeo[MAX_GEOHANDLE];
static id<MTLBuffer> QuadIB;

static sU32 State[0x310];         // Direct3D states, numbered like sD3D* (see _startdx.hpp)
static sInt SetupGen[MAX_SETUPS]; // incremented when a setup slot is reused
static sInt InstTex[MAX_TEXSTAGE];
static sVector VSConst[256];
static sVector PSConst[8];
static MTLScissorRect ScissorRect;

static id<MTLRenderPipelineState> ClearPipe[2][2];   // [rendertarget format is back buffer][write color]
static id<MTLRenderPipelineState> BlitPipe[2];       // [to drawable]
static id<MTLDepthStencilState> ClearDS[2];          // [write depth+stencil]
static id<MTLSamplerState> PointSampler,LinearSampler;

static std::map<std::string,id<MTLLibrary>> Libraries;
static std::map<std::string,id<MTLRenderPipelineState>> Pipelines;
static std::map<std::string,id<MTLDepthStencilState>> DepthStates;
static std::map<sU32,id<MTLSamplerState>> Samplers;

sInt MacDrawCalls;

static const sInt FVFSize[] = { 0,32,32,64,16,16,32,48 };  // see sFVF_??? in _start.hpp

/****************************************************************************/
/***                                                                      ***/
/***   Helpers                                                            ***/
/***                                                                      ***/
/****************************************************************************/

static const char *HelperMSL = R"(
#include <metal_stdlib>
using namespace metal;
struct CV { float4 pos [[position]]; };
vertex CV clearvs(uint vid [[vertex_id]])
{
  float2 t = float2((vid<<1)&2,vid&2);
  CV o; o.pos = float4(t*2.0-1.0,1.0,1.0); return o;
}
fragment float4 clearfs(constant float4 &c [[buffer(0)]]) { return c; }
struct BV { float4 pos [[position]]; float2 uv; };
vertex BV blitvs(uint vid [[vertex_id]],constant float4 &r [[buffer(0)]])
{
  float2 t = float2((vid<<1)&2,vid&2);
  BV o; o.pos = float4(t.x*2.0-1.0,1.0-t.y*2.0,0.0,1.0); o.uv = r.xy+t*r.zw; return o;
}
fragment float4 blitfs(BV i [[stage_in]],texture2d<float> t [[texture(0)]],sampler s [[sampler(0)]])
{
  return t.sample(s,i.uv);
}
)";

static void InitStates()
{
  sSetMem(State,0,sizeof(State));
  State[sD3DRS_ZENABLE] = 1;
  State[sD3DRS_FILLMODE] = 3;
  State[sD3DRS_ZWRITEENABLE] = 1;
  State[sD3DRS_SRCBLEND] = sD3DBLEND_ONE;
  State[sD3DRS_DESTBLEND] = sD3DBLEND_ZERO;
  State[sD3DRS_CULLMODE] = sD3DCULL_CCW;
  State[sD3DRS_ZFUNC] = sD3DCMP_LESSEQUAL;
  State[sD3DRS_ALPHAFUNC] = sD3DCMP_ALWAYS;
  State[sD3DRS_STENCILFAIL] = sD3DSTENCILOP_KEEP;
  State[sD3DRS_STENCILZFAIL] = sD3DSTENCILOP_KEEP;
  State[sD3DRS_STENCILPASS] = sD3DSTENCILOP_KEEP;
  State[sD3DRS_STENCILFUNC] = sD3DCMP_ALWAYS;
  State[sD3DRS_STENCILMASK] = 0xffffffff;
  State[sD3DRS_STENCILWRITEMASK] = 0xffffffff;
  State[sD3DRS_CCW_STENCILFAIL] = sD3DSTENCILOP_KEEP;
  State[sD3DRS_CCW_STENCILZFAIL] = sD3DSTENCILOP_KEEP;
  State[sD3DRS_CCW_STENCILPASS] = sD3DSTENCILOP_KEEP;
  State[sD3DRS_CCW_STENCILFUNC] = sD3DCMP_ALWAYS;
  State[sD3DRS_COLORWRITEENABLE] = 15;
  State[sD3DRS_BLENDOP] = sD3DBLENDOP_ADD;
  for(sInt s=0;s<16;s++)
  {
    State[0x200|(s<<4)|1] = sD3DTADDRESS_WRAP;
    State[0x200|(s<<4)|2] = sD3DTADDRESS_WRAP;
    State[0x200|(s<<4)|3] = sD3DTADDRESS_WRAP;
    State[0x200|(s<<4)|5] = sD3DTEXF_POINT;
    State[0x200|(s<<4)|6] = sD3DTEXF_POINT;
    State[0x200|(s<<4)|7] = sD3DTEXF_NONE;
    State[0x200|(s<<4)|10] = 1;
  }
  for(sInt i=0;i<MAX_TEXSTAGE;i++)
    InstTex[i] = sINVALID;
}

static id<MTLTexture> MakeTexture(MTLTextureType type,MTLPixelFormat fmt,sInt w,sInt h,sInt d,sInt mips,MTLTextureUsage usage,MTLStorageMode storage)
{
  MTLTextureDescriptor *td = [MTLTextureDescriptor new];
  td.textureType = type;
  td.pixelFormat = fmt;
  td.width = w;
  td.height = h;
  td.depth = d;
  td.mipmapLevelCount = mips;
  td.usage = usage;
  td.storageMode = storage;
  return [Dev newTextureWithDescriptor:td];
}

static id<MTLRenderPipelineState> MakePipe(id<MTLLibrary> lib,NSString *vs,NSString *fs,MTLPixelFormat color,sBool writeColor,sBool depth)
{
  MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
  pd.vertexFunction = [lib newFunctionWithName:vs];
  pd.fragmentFunction = [lib newFunctionWithName:fs];
  pd.colorAttachments[0].pixelFormat = color;
  pd.colorAttachments[0].writeMask = writeColor ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
  if(depth)
  {
    pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    pd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  }
  NSError *err = nil;
  id<MTLRenderPipelineState> p = [Dev newRenderPipelineStateWithDescriptor:pd error:&err];
  if(!p) fprintf(stderr,"pipeline: %s\n",err.localizedDescription.UTF8String);
  return p;
}

// the special textures of the D3D version (MakeCubeNormalizer, MakeAttenuationVolume)
static void MakeSpecialTextures()
{
  const sInt size = 64;
  static const sF32 faces[6][2][3] =
  {
    {{ 0, 0,-1},{ 0, 1, 0}},
    {{ 0, 0, 1},{ 0, 1, 0}},
    {{ 1, 0, 0},{ 0, 0,-1}},
    {{ 1, 0, 0},{ 0, 0, 1}},
    {{ 1, 0, 0},{ 0, 1, 0}},
    {{-1, 0, 0},{ 0, 1, 0}}
  };
  CubeNormalizer = MakeTexture(MTLTextureTypeCube,MTLPixelFormatBGRA8Unorm,size,size,1,1,MTLTextureUsageShaderRead,MTLStorageModeShared);
  static sU8 face[size*size*4];
  for(sInt i=0;i<6;i++)
  {
    sVector f0,f1,v;
    f0.Init(faces[i][0][0],faces[i][0][1],faces[i][0][2]);
    f1.Init(faces[i][1][0],faces[i][1][1],faces[i][1][2]);
    sU8 *p = face;
    for(sInt y=0;y<size;y++)
    {
      for(sInt x=0;x<size;x++)
      {
        v.Cross3(f0,f1);
        v.Scale3((size-1)*0.5f);
        v.AddScale3(f0,(x-(size-1)*0.5f));
        v.AddScale3(f1,(-y+(size-1)*0.5f));
        v.Unit3();
        p[0] = sFtol(128.0f+v.z*127);
        p[1] = sFtol(128.0f+v.y*127);
        p[2] = sFtol(128.0f+v.x*127);
        p[3] = 0;
        p += 4;
      }
    }
    [CubeNormalizer replaceRegion:MTLRegionMake2D(0,0,size,size) mipmapLevel:0 slice:i withBytes:face bytesPerRow:size*4 bytesPerImage:0];
  }

  const sInt vs = 32;
  const sF32 scale = 2.0f / (vs - 2.0f);
  const sF32 mid = vs / 2.0f;
  static sU8 vol[vs*vs*vs*4];
  sU8 *p = vol;
  for(sInt z=0;z<vs;z++)
  {
    for(sInt y=0;y<vs;y++)
    {
      for(sInt x=0;x<vs;x++)
      {
        sVector v;
        v.Init((x-mid)*scale,(y-mid)*scale,(z-mid)*scale);
        sF32 attn = sMax(1.0f - v.Dot3(v),0.0f);
        p[0] = p[1] = p[2] = p[3] = sFtol(attn * 255);
        p += 4;
      }
    }
  }
  AttenVolume = MakeTexture(MTLTextureType3D,MTLPixelFormatBGRA8Unorm,vs,vs,vs,1,MTLTextureUsageShaderRead,MTLStorageModeShared);
  [AttenVolume replaceRegion:MTLRegionMake3D(0,0,0,vs,vs,vs) mipmapLevel:0 slice:0 withBytes:vol bytesPerRow:vs*4 bytesPerImage:vs*vs*4];

  // unbound stages read as opaque black, like D3D
  static const sU32 black[6] = { 0xff000000,0xff000000,0xff000000,0xff000000,0xff000000,0xff000000 };
  Dummy2D = MakeTexture(MTLTextureType2D,MTLPixelFormatBGRA8Unorm,1,1,1,1,MTLTextureUsageShaderRead,MTLStorageModeShared);
  [Dummy2D replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:black bytesPerRow:4];
  DummyCube = MakeTexture(MTLTextureTypeCube,MTLPixelFormatBGRA8Unorm,1,1,1,1,MTLTextureUsageShaderRead,MTLStorageModeShared);
  for(sInt i=0;i<6;i++)
    [DummyCube replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 slice:i withBytes:black bytesPerRow:4 bytesPerImage:0];
  Dummy3D = MakeTexture(MTLTextureType3D,MTLPixelFormatBGRA8Unorm,1,1,1,1,MTLTextureUsageShaderRead,MTLStorageModeShared);
  [Dummy3D replaceRegion:MTLRegionMake3D(0,0,0,1,1,1) mipmapLevel:0 slice:0 withBytes:black bytesPerRow:4 bytesPerImage:4];
}

void MacRenderInit(NSView *view,sInt xs,sInt ys)
{
  Dev = MTLCreateSystemDefaultDevice();
  if(!Dev)
  {
    fprintf(stderr,"fatal error: no Metal device\n");
    exit(1);
  }
  Queue = [Dev newCommandQueue];
  FrameSem = dispatch_semaphore_create(FramesInFlight);
  for(int i=0;i<FramesInFlight;i++)
    Ring[i] = [Dev newBufferWithLength:RingSize options:MTLResourceStorageModeShared|MTLResourceCPUCacheModeWriteCombined];

  BackColor = MakeTexture(MTLTextureType2D,MTLPixelFormatBGRA8Unorm,xs,ys,1,1,
    MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead,MTLStorageModePrivate);
  BackDepth = MakeTexture(MTLTextureType2D,MTLPixelFormatDepth32Float_Stencil8,xs,ys,1,1,
    MTLTextureUsageRenderTarget,MTLStorageModePrivate);

  // quads: 0,1,2, 0,2,3 like GeoBuffer[3] of the D3D version
  const sInt quads = 0x8000/6;
  sU16 *qi = new sU16[quads*6], *ip = qi;
  for(sInt i=0;i<quads;i++)
    sQuad(ip,i*4+0,i*4+1,i*4+2,i*4+3);
  QuadIB = [Dev newBufferWithBytes:qi length:quads*12 options:MTLResourceStorageModeShared];
  delete[] qi;

  NSError *err = nil;
  id<MTLLibrary> lib = [Dev newLibraryWithSource:[NSString stringWithUTF8String:HelperMSL] options:nil error:&err];
  if(!lib)
  {
    fprintf(stderr,"fatal error: %s\n",err.localizedDescription.UTF8String);
    exit(1);
  }
  for(sInt c=0;c<2;c++)
  {
    ClearPipe[0][c] = MakePipe(lib,@"clearvs",@"clearfs",MTLPixelFormatBGRA8Unorm,c,sTRUE);
    ClearPipe[1][c] = ClearPipe[0][c];
  }
  BlitPipe[0] = MakePipe(lib,@"blitvs",@"blitfs",MTLPixelFormatBGRA8Unorm,sTRUE,sFALSE);
  BlitPipe[1] = BlitPipe[0];

  MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
  dd.depthCompareFunction = MTLCompareFunctionAlways;
  dd.depthWriteEnabled = NO;
  ClearDS[0] = [Dev newDepthStencilStateWithDescriptor:dd];
  dd.depthWriteEnabled = YES;
  MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
  sd.stencilCompareFunction = MTLCompareFunctionAlways;
  sd.depthStencilPassOperation = MTLStencilOperationReplace;
  sd.writeMask = 0xff;
  dd.frontFaceStencil = sd;
  dd.backFaceStencil = sd;
  ClearDS[1] = [Dev newDepthStencilStateWithDescriptor:dd];

  MTLSamplerDescriptor *smp = [MTLSamplerDescriptor new];
  smp.minFilter = smp.magFilter = MTLSamplerMinMagFilterNearest;
  smp.sAddressMode = smp.tAddressMode = MTLSamplerAddressModeClampToEdge;
  PointSampler = [Dev newSamplerStateWithDescriptor:smp];
  smp.minFilter = smp.magFilter = MTLSamplerMinMagFilterLinear;
  LinearSampler = [Dev newSamplerStateWithDescriptor:smp];

  MakeSpecialTextures();
  InitStates();

  // texture handle 0 stays reserved: GenOverlayManager's materials use
  // SetTex(i,0) as a placeholder and add/remove references to handle 0 long
  // before the first real texture exists. a real texture in slot 0 would be
  // released by them while still in use (the hud font did exactly that).
  sHardTex *t0 = &sSystem->Textures[0];
  t0->Flags = sTIF_ALLOCATED;
  t0->RefCount = 0x40000000;
  t0->XSize = t0->YSize = 1;
  t0->Format = sTF_A8R8G8B8;
  t0->MipLevels = 1;
  MTex[0].Tex = Dummy2D;

  if(view)
  {
    LayerView = view;
    Layer = [CAMetalLayer layer];
    Layer.device = Dev;
    Layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    Layer.framebufferOnly = YES;
    view.layer = Layer;
    view.wantsLayer = YES;
  }
}

/****************************************************************************/
/***                                                                      ***/
/***   Command buffers and passes                                         ***/
/***                                                                      ***/
/****************************************************************************/

static id<MTLCommandBuffer> GetCmd()
{
  if(!Cmd)
  {
    dispatch_semaphore_wait(FrameSem,DISPATCH_TIME_FOREVER);
    Cmd = [Queue commandBuffer];
    dispatch_semaphore_t sem = FrameSem;
    [Cmd addCompletedHandler:^(id<MTLCommandBuffer> b) { dispatch_semaphore_signal(sem); }];
    RingIndex = (RingIndex+1)%FramesInFlight;
    RingPos = 0;
  }
  return Cmd;
}

static void EndPass()
{
  if(Enc)
  {
    [Enc endEncoding];
    Enc = nil;
  }
  EncTarget = -1000;
}

static void TargetSize(sInt target,sInt &w,sInt &h)
{
  if(target<0)
  {
    w = (sInt)BackColor.width;
    h = (sInt)BackColor.height;
  }
  else
  {
    w = (sInt)MTex[target].Tex.width;
    h = (sInt)MTex[target].Tex.height;
  }
}

// make sure the encoder renders into the target of the current viewport
static sBool EnsurePass()
{
  sInt target = sSystem->CurrentViewport.RenderTarget;
  if(target>=0 && !MTex[target].Tex)
    return sFALSE;
  if(Enc && EncTarget==target)
    return sTRUE;

  EndPass();
  MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
  id<MTLTexture> color = target<0 ? BackColor : MTex[target].Tex;
  id<MTLTexture> depth = BackDepth;
  if(target>=0)
  {
    if(!MTex[target].Depth)
      MTex[target].Depth = MakeTexture(MTLTextureType2D,MTLPixelFormatDepth32Float_Stencil8,color.width,color.height,1,1,
        MTLTextureUsageRenderTarget,MTLStorageModePrivate);
    depth = MTex[target].Depth;
  }
  rp.colorAttachments[0].texture = color;
  rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
  rp.colorAttachments[0].storeAction = MTLStoreActionStore;
  rp.depthAttachment.texture = depth;
  rp.depthAttachment.loadAction = MTLLoadActionLoad;
  rp.depthAttachment.storeAction = MTLStoreActionStore;
  rp.stencilAttachment.texture = depth;
  rp.stencilAttachment.loadAction = MTLLoadActionLoad;
  rp.stencilAttachment.storeAction = MTLStoreActionStore;
  Enc = [GetCmd() renderCommandEncoderWithDescriptor:rp];
  EncTarget = target;
  return sTRUE;
}

static void SetViewportAndScissor()
{
  sInt tw,th;
  TargetSize(EncTarget,tw,th);
  const sRect &w = sSystem->CurrentViewport.Window;
  MTLViewport vp = { (double)w.x0,(double)w.y0,(double)w.XSize(),(double)w.YSize(),0.0,1.0 };
  [Enc setViewport:vp];

  MTLScissorRect sr;
  if(State[sD3DRS_SCISSORTESTENABLE])
    sr = ScissorRect;
  else
  {
    sr.x = 0; sr.y = 0; sr.width = tw; sr.height = th;
  }
  // metal wants the scissor inside the target
  NSUInteger x0 = sMin<NSUInteger>(sr.x,tw), y0 = sMin<NSUInteger>(sr.y,th);
  NSUInteger x1 = sMin<NSUInteger>(sr.x+sr.width,tw), y1 = sMin<NSUInteger>(sr.y+sr.height,th);
  sr.x = x0; sr.y = y0; sr.width = x1-x0; sr.height = y1-y0;
  [Enc setScissorRect:sr];
}

static void *RingAlloc(size_t size,__strong id<MTLBuffer> &buf,size_t &offset)
{
  size = (size+255)&~(size_t)255;
  if(RingPos+size > RingSize)
    return 0;
  buf = Ring[RingIndex];
  offset = RingPos;
  RingPos += size;
  return (sU8 *)buf.contents + offset;
}

// scale the back buffer into the drawable, keep the aspect ratio
void MacRenderPresent()
{
  EndPass();
  id<MTLCommandBuffer> cmd = GetCmd();
  if(Layer)
  {
    @autoreleasepool
    {
      NSSize size = LayerView.bounds.size;
      CGFloat scale = LayerView.window ? LayerView.window.backingScaleFactor : 1.0;
      Layer.contentsScale = scale;
      Layer.drawableSize = CGSizeMake(sMax<CGFloat>(1,size.width*scale),sMax<CGFloat>(1,size.height*scale));
      id<CAMetalDrawable> drawable = [Layer nextDrawable];
      if(drawable)
      {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = drawable.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [cmd renderCommandEncoderWithDescriptor:rp];
        double dw = drawable.texture.width, dh = drawable.texture.height;
        double bw = BackColor.width, bh = BackColor.height;
        double s = sMin(dw/bw,dh/bh);
        MTLViewport vp = { (dw-bw*s)*0.5,(dh-bh*s)*0.5,bw*s,bh*s,0.0,1.0 };
        [e setViewport:vp];
        [e setRenderPipelineState:BlitPipe[1]];
        sF32 r[4] = { 0,0,1,1 };
        [e setVertexBytes:r length:16 atIndex:0];
        [e setFragmentTexture:BackColor atIndex:0];
        [e setFragmentSamplerState:LinearSampler atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        [cmd presentDrawable:drawable];
      }
    }
  }
  [cmd commit];
  Cmd = nil;
}

// read back the back buffer and write it as PNG
void MacRenderScreenshot(const char *path)
{
  EndPass();
  id<MTLCommandBuffer> cmd = GetCmd();
  sInt w = (sInt)BackColor.width, h = (sInt)BackColor.height;
  id<MTLBuffer> buf = [Dev newBufferWithLength:w*h*4 options:MTLResourceStorageModeShared];
  id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
  [b copyFromTexture:BackColor sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1)
    toBuffer:buf destinationOffset:0 destinationBytesPerRow:w*4 destinationBytesPerImage:w*h*4];
  [b endEncoding];
  [cmd commit];
  [cmd waitUntilCompleted];
  Cmd = nil;

  sU8 *p = (sU8 *)buf.contents;
  for(sInt i=0;i<w*h;i++) p[i*4+3] = 255;   // the game leaves alpha undefined
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(p,w,h,8,w*4,cs,kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
  CGImageRef img = CGBitmapContextCreateImage(ctx);
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(0,(const UInt8 *)path,strlen(path),false);
  CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url,CFSTR("public.png"),1,0);
  if(dst)
  {
    CGImageDestinationAddImage(dst,img,0);
    CGImageDestinationFinalize(dst);
    CFRelease(dst);
  }
  CFRelease(url);
  CGImageRelease(img);
  CGContextRelease(ctx);
  CGColorSpaceRelease(cs);
}

/****************************************************************************/
/***                                                                      ***/
/***   Clear, viewport, grab                                              ***/
/***                                                                      ***/
/****************************************************************************/

static void ClearRect(sU32 flags,sU32 color)
{
  if(!EnsurePass())
    return;
  SetViewportAndScissor();
  sBool writeColor = (flags & sVCF_COLOR) != 0;
  sBool writeZ = (flags & (sVCF_Z|sVCF_STENCIL)) != 0;
  if(!writeColor && !writeZ)
    return;
  [Enc setRenderPipelineState:ClearPipe[EncTarget<0][writeColor]];
  [Enc setDepthStencilState:ClearDS[writeZ]];
  [Enc setStencilReferenceValue:0];
  [Enc setCullMode:MTLCullModeNone];
  sF32 c[4] = { ((color>>16)&255)/255.0f,((color>>8)&255)/255.0f,(color&255)/255.0f,((color>>24)&255)/255.0f };
  [Enc setFragmentBytes:c length:16 atIndex:0];
  [Enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

void sSystem_::Clear(sU32 flags,sU32 color)
{
  ClearRect(flags,color);
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
  if(!scissor)
    SetState(sD3DRS_SCISSORTESTENABLE,0);
  else
  {
    const sRect &w = CurrentViewport.Window;
    sInt x0 = w.x0 + (w.x1 - w.x0) * (1.0f + scissor->x0) * 0.5f;
    sInt x1 = w.x0 + (w.x1 - w.x0) * (1.0f + scissor->x1) * 0.5f;
    sInt y0 = w.y0 + (w.y1 - w.y0) * (1.0f - scissor->y1) * 0.5f;
    sInt y1 = w.y0 + (w.y1 - w.y0) * (1.0f - scissor->y0) * 0.5f;
    x0 = sMax(x0,0); y0 = sMax(y0,0);
    ScissorRect.x = x0;
    ScissorRect.y = y0;
    ScissorRect.width = sMax(x1-x0,0);
    ScissorRect.height = sMax(y1-y0,0);
    SetState(sD3DRS_SCISSORTESTENABLE,1);
  }
}

// StretchRect from the back buffer or a render target into a texture
void sSystem_::GrabScreen(sInt sourceRT,const sRect &win,sInt tex,sBool stretch)
{
  id<MTLTexture> src = sourceRT==-1 ? BackColor : MTex[sourceRT].Tex;
  id<MTLTexture> dst = MTex[tex].Tex;
  if(!src || !dst)
    return;
  EndPass();
  if(!stretch)
  {
    NSUInteger w = sMin<NSUInteger>(win.XSize(),dst.width), h = sMin<NSUInteger>(win.YSize(),dst.height);
    w = sMin<NSUInteger>(w,src.width-win.x0);
    h = sMin<NSUInteger>(h,src.height-win.y0);
    id<MTLBlitCommandEncoder> b = [GetCmd() blitCommandEncoder];
    [b copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(win.x0,win.y0,0) sourceSize:MTLSizeMake(w,h,1)
      toTexture:dst destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [b endEncoding];
  }
  else
  {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [GetCmd() renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:BlitPipe[0]];
    sF32 r[4] = { (sF32)win.x0/src.width,(sF32)win.y0/src.height,(sF32)win.XSize()/src.width,(sF32)win.YSize()/src.height };
    [e setVertexBytes:r length:16 atIndex:0];
    [e setFragmentTexture:src atIndex:0];
    [e setFragmentSamplerState:PointSampler atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
  }
}

// the loading bar of the D3D version (three ColorFills)
void MacRenderProgress(sInt done,sInt max)
{
  const int step = 3;
  sViewport vp;
  vp.Init();
  sSystem->SetViewport(vp);
  sSystem->SetState(sD3DRS_SCISSORTESTENABLE,0);
  ClearRect(sVCF_COLOR,0xff000000);
  sInt cx = sSystem->ConfigX, cy = sSystem->ConfigY;
  for(sInt i=0;i<3;i++)
  {
    sRect r;
    r.Init(20+step*i,cy/2-20+step*i,cx-20-step*i,cy/2+20-step*i);
    if(i==2) r.x1 = r.x0 + 1 + sMin(max,done)*(r.x1-r.x0-1)/sMax(max,1);
    ScissorRect.x = r.x0; ScissorRect.y = r.y0; ScissorRect.width = r.XSize(); ScissorRect.height = r.YSize();
    State[sD3DRS_SCISSORTESTENABLE] = 1;
    ClearRect(sVCF_COLOR,(i&1) ? 0xff000000 : 0xffffffff);
  }
  State[sD3DRS_SCISSORTESTENABLE] = 0;
  MacRenderPresent();
}

/****************************************************************************/
/***                                                                      ***/
/***   Textures                                                           ***/
/***                                                                      ***/
/****************************************************************************/

static MTLPixelFormat TexFormat(sInt format)
{
  switch(format)
  {
  case sTF_Q8W8V8U8: return MTLPixelFormatRGBA8Snorm;
  case sTF_R16F: return MTLPixelFormatR16Float;
  default: return MTLPixelFormatBGRA8Unorm;
  }
}

// convert 16 bit per channel data (B,G,R,A) to 8 bit and build the mip chain
// exactly like sSystem_::UpdateTexture of the D3D version
static void UploadTexture(sHardTex *ht,id<MTLTexture> tex,const sU16 *source,sInt miptresh)
{
  sInt mipdir = miptresh & 16;
  miptresh &= 15;
  sInt xs = ht->XSize, ys = ht->YSize, oxs = xs;
  sU32 *data = new sU32[xs*ys*2];
  sU32 *line = new sU32[xs];
  sCopyMem(data,source,xs*ys*8);

  for(sInt level=0;level<(sInt)tex.mipmapLevelCount;level++)
  {
    for(sInt y=0;y<ys;y++)
    {
      const sU16 *s16 = (const sU16 *)(data + y*oxs*2);
      for(sInt x=0;x<xs;x++)
      {
        if(ht->Format==sTF_Q8W8V8U8)
          line[x] = (((((sInt)s16[2]-0x4000)>>7)&0xff)    ) |
                    (((((sInt)s16[1]-0x4000)>>7)&0xff)<< 8) |
                    (((((sInt)s16[0]-0x4000)>>7)&0xff)<<16) |
                    (((((sInt)s16[3]-0x4000)>>7)&0xff)<<24);
        else
          line[x] = (((s16[0]>>7)&0xff)    ) |
                    (((s16[1]>>7)&0xff)<< 8) |
                    (((s16[2]>>7)&0xff)<<16) |
                    (((s16[3]>>7)&0xff)<<24);
        s16 += 4;
      }
      [tex replaceRegion:MTLRegionMake2D(0,y,xs,1) mipmapLevel:level withBytes:line bytesPerRow:xs*4];
    }

    if(level+1>=(sInt)tex.mipmapLevelCount)
      break;

    sBool filter = (miptresh <= level);
    if(mipdir) filter = !filter;
    for(sInt y=0;y<ys/2;y++)
    {
      const sU16 *s16 = (const sU16 *)(data + y*2*oxs*2);
      sU16 *d16 = (sU16 *)(data + y*oxs*2);
      for(sInt x=0;x<xs/2;x++)
      {
        for(sInt c=0;c<4;c++)
          d16[c] = filter ? (s16[c]+s16[4+c]+s16[oxs*4+c]+s16[oxs*4+4+c]+2)>>2 : s16[c];
        d16 += 4;
        s16 += 8;
      }
    }
    xs >>= 1;
    ys >>= 1;
  }
  delete[] line;
  delete[] data;
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
        MTex[i].Tex = MakeTexture(MTLTextureType2D,TexFormat(format)==MTLPixelFormatRGBA8Snorm ? MTLPixelFormatBGRA8Unorm : TexFormat(format),
          tex->XSize,tex->YSize,1,1,MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead,MTLStorageModePrivate);
      }
      else
      {
        // full chain (mipcount 0) stops where the smaller side reaches 1, like the D3D upload loop
        sInt levels = sMin(sGetPower2(xs),sGetPower2(ys))+1;
        if(mipcount) levels = sMin(levels,mipcount);
        MTex[i].Tex = MakeTexture(MTLTextureType2D,TexFormat(format),xs,ys,1,levels,MTLTextureUsageShaderRead,MTLStorageModeShared);
        UploadTexture(tex,MTex[i].Tex,data,miptresh);
      }
      MTex[i].Depth = nil;
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
      if(EncTarget==handle)
        EndPass();
      MTex[handle].Tex = nil;
      MTex[handle].Depth = nil;
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

// top level of a texture as 32 bit texels (test option --dump-textures)
sBool MacReadTexture(sInt handle,sU32 *dest)
{
  id<MTLTexture> t = MTex[handle].Tex;
  if(!t || t.storageMode==MTLStorageModePrivate)
    return sFALSE;
  [t getBytes:dest bytesPerRow:t.width*4 fromRegion:MTLRegionMake2D(0,0,t.width,t.height) mipmapLevel:0];
  return sTRUE;
}

/****************************************************************************/
/***                                                                      ***/
/***   Render states and material setups                                  ***/
/***                                                                      ***/
/****************************************************************************/

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
  if(token<0x310)
    State[token] = value;
}

static sInt ShaderLength(const sU32 *code)
{
  if(!code) return 0;
  sInt i = 0;
  while(code[i]!=XO_END) i++;
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
  SetupGen[id]++;
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
  for(sInt i=0;i<inst.NumTextures && i<MAX_TEXSTAGE;i++)
    InstTex[i] = CurrentTextures[i] = inst.Textures[i];
  if(inst.NumVSConstants)
    sCopyMem(VSConst,inst.VSConstants,sMin(inst.NumVSConstants,256)*sizeof(sVector));
  if(inst.NumPSConstants)
    sCopyMem(PSConst,inst.PSConstants,sMin(inst.NumPSConstants,8)*sizeof(sVector));
}

/****************************************************************************/

static MTLBlendFactor BlendFactor(sU32 b)
{
  switch(b)
  {
  case sD3DBLEND_ZERO: return MTLBlendFactorZero;
  case sD3DBLEND_ONE: return MTLBlendFactorOne;
  case sD3DBLEND_SRCCOLOR: return MTLBlendFactorSourceColor;
  case sD3DBLEND_INVSRCCOLOR: return MTLBlendFactorOneMinusSourceColor;
  case sD3DBLEND_SRCALPHA: return MTLBlendFactorSourceAlpha;
  case sD3DBLEND_INVSRCALPHA: return MTLBlendFactorOneMinusSourceAlpha;
  case sD3DBLEND_DESTALPHA: return MTLBlendFactorDestinationAlpha;
  case sD3DBLEND_INVDESTALPHA: return MTLBlendFactorOneMinusDestinationAlpha;
  case sD3DBLEND_DESTCOLOR: return MTLBlendFactorDestinationColor;
  case sD3DBLEND_INVDESTCOLOR: return MTLBlendFactorOneMinusDestinationColor;
  case sD3DBLEND_SRCALPHASAT: return MTLBlendFactorSourceAlphaSaturated;
  }
  return MTLBlendFactorOne;
}

static MTLBlendOperation BlendOp(sU32 op)
{
  switch(op)
  {
  case sD3DBLENDOP_SUBTRACT: return MTLBlendOperationSubtract;
  case sD3DBLENDOP_REVSUBTRACT: return MTLBlendOperationReverseSubtract;
  case sD3DBLENDOP_MIN: return MTLBlendOperationMin;
  case sD3DBLENDOP_MAX: return MTLBlendOperationMax;
  }
  return MTLBlendOperationAdd;
}

static MTLCompareFunction CompareFunc(sU32 f)
{
  switch(f)
  {
  case sD3DCMP_NEVER: return MTLCompareFunctionNever;
  case sD3DCMP_LESS: return MTLCompareFunctionLess;
  case sD3DCMP_EQUAL: return MTLCompareFunctionEqual;
  case sD3DCMP_LESSEQUAL: return MTLCompareFunctionLessEqual;
  case sD3DCMP_GREATER: return MTLCompareFunctionGreater;
  case sD3DCMP_NOTEQUAL: return MTLCompareFunctionNotEqual;
  case sD3DCMP_GREATEREQUAL: return MTLCompareFunctionGreaterEqual;
  }
  return MTLCompareFunctionAlways;
}

static MTLStencilOperation StencilOp(sU32 op)
{
  switch(op)
  {
  case sD3DSTENCILOP_ZERO: return MTLStencilOperationZero;
  case sD3DSTENCILOP_REPLACE: return MTLStencilOperationReplace;
  case sD3DSTENCILOP_INCRSAT: return MTLStencilOperationIncrementClamp;
  case sD3DSTENCILOP_DECRSAT: return MTLStencilOperationDecrementClamp;
  case sD3DSTENCILOP_INVERT: return MTLStencilOperationInvert;
  case sD3DSTENCILOP_INCR: return MTLStencilOperationIncrementWrap;
  case sD3DSTENCILOP_DECR: return MTLStencilOperationDecrementWrap;
  }
  return MTLStencilOperationKeep;
}

// vertex layouts of the FVF table in _start.cpp
static MTLVertexDescriptor *VertexDescriptor(sInt fvf,sU32 &attribMask)
{
  struct Elem { sInt slot; MTLVertexFormat fmt; sInt offset; };
  const MTLVertexFormat F2 = MTLVertexFormatFloat2, F3 = MTLVertexFormatFloat3, F4 = MTLVertexFormatFloat4,
    C = MTLVertexFormatUChar4Normalized_BGRA;
  static const Elem layouts[8][8] =
  {
    { {-1} },
    { {D3D9MSL_ATTR_POSITION,F3,0},{D3D9MSL_ATTR_NORMAL,F3,12},{D3D9MSL_ATTR_TEXCOORD0,F2,24},{-1} },
    { {D3D9MSL_ATTR_POSITION,F3,0},{D3D9MSL_ATTR_COLOR0,C,12},{D3D9MSL_ATTR_TEXCOORD0,F2,16},{D3D9MSL_ATTR_TEXCOORD0+1,F2,24},{-1} },
    { {D3D9MSL_ATTR_POSITION,F3,0},{D3D9MSL_ATTR_NORMAL,F3,12},{D3D9MSL_ATTR_COLOR0,C,24},{D3D9MSL_ATTR_COLOR1,C,28},
      {D3D9MSL_ATTR_TEXCOORD0,F2,32},{D3D9MSL_ATTR_TANGENT,F3,40},{D3D9MSL_ATTR_BINORMAL,F3,52},{-1} },
    { {D3D9MSL_ATTR_POSITION,F3,0},{D3D9MSL_ATTR_COLOR0,C,12},{-1} },
    { {D3D9MSL_ATTR_POSITION,F4,0},{-1} },
    { {D3D9MSL_ATTR_POSITION,F3,0},{D3D9MSL_ATTR_NORMAL,C,12},{D3D9MSL_ATTR_TANGENT,C,16},{D3D9MSL_ATTR_COLOR0,C,20},{D3D9MSL_ATTR_TEXCOORD0,F2,24},{-1} },
    { {D3D9MSL_ATTR_POSITION,F3,0},{D3D9MSL_ATTR_NORMAL,F3,12},{D3D9MSL_ATTR_TANGENT,F3,24},{D3D9MSL_ATTR_COLOR0,C,36},{D3D9MSL_ATTR_TEXCOORD0,F2,40},{-1} },
  };
  MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
  attribMask = 0;
  for(const Elem *e = layouts[fvf];e->slot>=0;e++)
  {
    vd.attributes[e->slot].format = e->fmt;
    vd.attributes[e->slot].offset = e->offset;
    vd.attributes[e->slot].bufferIndex = 0;
    attribMask |= 1u<<e->slot;
  }
  vd.layouts[0].stride = FVFSize[fvf];
  return vd;
}

static sU32 TexTypes()
{
  sU32 types = 0;
  for(sInt i=0;i<4;i++)
  {
    if(InstTex[i]==-2) types |= D3D9MSL_TEXCUBE<<(i*2);
    if(InstTex[i]==-3) types |= D3D9MSL_TEX3D<<(i*2);
  }
  return types;
}

static id<MTLRenderPipelineState> GetPipeline(sInt fvf)
{
  sInt sid = sSystem->CurrentSetupId;
  if(sid<0)
    return nil;
  sMaterialSetup *setup = &sSystem->Setups[sid];
  sU32 types = TexTypes();
  MTLPixelFormat fmt = EncTarget<0 ? MTLPixelFormatBGRA8Unorm : MTex[EncTarget].Tex.pixelFormat;
  sBool blend = State[sD3DRS_ALPHABLENDENABLE]!=0;

  char key[160];
  snprintf(key,sizeof(key),"%d.%d.%x.%d.%d.%d.%x.%x.%x.%x",sid,SetupGen[sid],types,fvf,(int)fmt,blend,
    blend ? State[sD3DRS_SRCBLEND] : 0,blend ? State[sD3DRS_DESTBLEND] : 0,blend ? State[sD3DRS_BLENDOP] : 0,
    State[sD3DRS_COLORWRITEENABLE]&15);
  auto it = Pipelines.find(key);
  if(it!=Pipelines.end())
    return it->second;

  sU32 attribMask;
  MTLVertexDescriptor *vd = VertexDescriptor(fvf,attribMask);

  char libkey[64];
  snprintf(libkey,sizeof(libkey),"%d.%d.%x.%x",sid,SetupGen[sid],types,attribMask);
  id<MTLLibrary> lib = Libraries[libkey];
  if(!lib)
  {
    std::string msl,err;
    if(!D3D9ToMSL(setup->VSCode,setup->PSCode,types,attribMask,msl,err))
    {
      fprintf(stderr,"shader translation failed: %s\n",err.c_str());
      Pipelines[key] = nil;
      return nil;
    }
    NSError *nerr = nil;
    // the passes of a material are drawn with zfunc equal: every shader must
    // compute exactly the same positions, like D3D9 guaranteed
    static MTLCompileOptions *opt;
    if(!opt)
    {
      opt = [MTLCompileOptions new];
      opt.preserveInvariance = YES;
    }
    lib = [Dev newLibraryWithSource:[NSString stringWithUTF8String:msl.c_str()] options:opt error:&nerr];
    if(!lib)
    {
      fprintf(stderr,"shader compile failed: %s\n%s\n",nerr.localizedDescription.UTF8String,msl.c_str());
      Pipelines[key] = nil;
      return nil;
    }
    Libraries[libkey] = lib;
  }

  MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
  pd.vertexFunction = [lib newFunctionWithName:@"vsmain"];
  pd.fragmentFunction = [lib newFunctionWithName:@"psmain"];
  pd.vertexDescriptor = vd;
  MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[0];
  ca.pixelFormat = fmt;
  sU32 mask = State[sD3DRS_COLORWRITEENABLE];
  ca.writeMask = ((mask&1) ? MTLColorWriteMaskRed : 0) | ((mask&2) ? MTLColorWriteMaskGreen : 0) |
                 ((mask&4) ? MTLColorWriteMaskBlue : 0) | ((mask&8) ? MTLColorWriteMaskAlpha : 0);
  if(blend)
  {
    ca.blendingEnabled = YES;
    ca.sourceRGBBlendFactor = ca.sourceAlphaBlendFactor = BlendFactor(State[sD3DRS_SRCBLEND]);
    ca.destinationRGBBlendFactor = ca.destinationAlphaBlendFactor = BlendFactor(State[sD3DRS_DESTBLEND]);
    ca.rgbBlendOperation = ca.alphaBlendOperation = BlendOp(State[sD3DRS_BLENDOP]);
  }
  pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  pd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
  NSError *err = nil;
  id<MTLRenderPipelineState> p = [Dev newRenderPipelineStateWithDescriptor:pd error:&err];
  if(!p)
    fprintf(stderr,"pipeline failed: %s\n",err.localizedDescription.UTF8String);
  Pipelines[key] = p;
  return p;
}

static id<MTLDepthStencilState> GetDepthState()
{
  sBool z = State[sD3DRS_ZENABLE]!=0;
  sBool st = State[sD3DRS_STENCILENABLE]!=0;
  sBool two = st && State[sD3DRS_TWOSIDEDSTENCILMODE]!=0;
  char key[160];
  snprintf(key,sizeof(key),"%d.%d.%d.%d.%d.%x.%x.%x.%x.%x.%x.%x.%x.%x.%x",z,z && State[sD3DRS_ZWRITEENABLE],z ? State[sD3DRS_ZFUNC] : 0,st,two,
    st ? State[sD3DRS_STENCILFUNC] : 0,st ? State[sD3DRS_STENCILFAIL] : 0,st ? State[sD3DRS_STENCILZFAIL] : 0,st ? State[sD3DRS_STENCILPASS] : 0,
    st ? State[sD3DRS_STENCILMASK]&0xff : 0,st ? State[sD3DRS_STENCILWRITEMASK]&0xff : 0,
    two ? State[sD3DRS_CCW_STENCILFUNC] : 0,two ? State[sD3DRS_CCW_STENCILFAIL] : 0,two ? State[sD3DRS_CCW_STENCILZFAIL] : 0,two ? State[sD3DRS_CCW_STENCILPASS] : 0);
  auto it = DepthStates.find(key);
  if(it!=DepthStates.end())
    return it->second;

  MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
  dd.depthCompareFunction = z ? CompareFunc(State[sD3DRS_ZFUNC]) : MTLCompareFunctionAlways;
  dd.depthWriteEnabled = z && State[sD3DRS_ZWRITEENABLE];
  if(st)
  {
    MTLStencilDescriptor *front = [MTLStencilDescriptor new];
    front.stencilCompareFunction = CompareFunc(State[sD3DRS_STENCILFUNC]);
    front.stencilFailureOperation = StencilOp(State[sD3DRS_STENCILFAIL]);
    front.depthFailureOperation = StencilOp(State[sD3DRS_STENCILZFAIL]);
    front.depthStencilPassOperation = StencilOp(State[sD3DRS_STENCILPASS]);
    front.readMask = State[sD3DRS_STENCILMASK]&0xff;
    front.writeMask = State[sD3DRS_STENCILWRITEMASK]&0xff;
    MTLStencilDescriptor *back = front;
    if(two)
    {
      back = [MTLStencilDescriptor new];
      back.stencilCompareFunction = CompareFunc(State[sD3DRS_CCW_STENCILFUNC]);
      back.stencilFailureOperation = StencilOp(State[sD3DRS_CCW_STENCILFAIL]);
      back.depthFailureOperation = StencilOp(State[sD3DRS_CCW_STENCILZFAIL]);
      back.depthStencilPassOperation = StencilOp(State[sD3DRS_CCW_STENCILPASS]);
      back.readMask = front.readMask;
      back.writeMask = front.writeMask;
    }
    dd.frontFaceStencil = front;
    dd.backFaceStencil = back;
  }
  id<MTLDepthStencilState> s = [Dev newDepthStencilStateWithDescriptor:dd];
  DepthStates[key] = s;
  return s;
}

static id<MTLSamplerState> GetSampler(sInt stage)
{
  const sU32 *ss = State + (0x200|(stage<<4));
  sU32 key = (ss[1]&7) | (ss[2]&7)<<3 | (ss[3]&7)<<6 | (ss[5]&3)<<9 | (ss[6]&3)<<11 | (ss[7]&3)<<13 | (sMin<sU32>(ss[10],16))<<15;
  auto it = Samplers.find(key);
  if(it!=Samplers.end())
    return it->second;

  static const MTLSamplerAddressMode addr[8] =
  {
    MTLSamplerAddressModeRepeat,MTLSamplerAddressModeRepeat,MTLSamplerAddressModeMirrorRepeat,MTLSamplerAddressModeClampToEdge,
    MTLSamplerAddressModeClampToBorderColor,MTLSamplerAddressModeMirrorClampToEdge,MTLSamplerAddressModeRepeat,MTLSamplerAddressModeRepeat,
  };
  MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
  sd.sAddressMode = addr[ss[1]&7];
  sd.tAddressMode = addr[ss[2]&7];
  sd.rAddressMode = addr[ss[3]&7];
  sd.borderColor = MTLSamplerBorderColorTransparentBlack;
  sd.magFilter = ss[5]>=sD3DTEXF_LINEAR ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
  sd.minFilter = ss[6]>=sD3DTEXF_LINEAR ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
  sd.mipFilter = ss[7]==sD3DTEXF_NONE ? MTLSamplerMipFilterNotMipmapped : ss[7]==sD3DTEXF_POINT ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterLinear;
  if(ss[5]==sD3DTEXF_ANISOTROPIC || ss[6]==sD3DTEXF_ANISOTROPIC)
    sd.maxAnisotropy = sRange<sU32>(ss[10],16,1);
  id<MTLSamplerState> s = [Dev newSamplerStateWithDescriptor:sd];
  Samplers[key] = s;
  return s;
}

static id<MTLTexture> StageTexture(sInt stage)
{
  sInt h = InstTex[stage];
  if(h==-2) return CubeNormalizer;
  if(h==-3) return AttenVolume;
  if(h>=0 && h<MAX_TEXTURE && MTex[h].Tex)
    return MTex[h].Tex;
  return Dummy2D;
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
      MGeo[i].Dirty = sGEO_VERTEX|sGEO_INDEX;
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
  MacGeo *mg = &MGeo[handle];
  delete[] mg->Vertex;
  delete[] mg->Index;
  mg->Vertex = mg->Index = 0;
  mg->VertexAlloc = mg->IndexAlloc = 0;
  mg->VB = mg->IB = nil;
  mg->Dirty = 0;
  GeoHandle[handle].Mode = 0;
}

// dynamic buffers are "discarded" on request; static ones stay valid
void sSystem_::GeoFlush(sInt handle,sInt what)
{
  sVERIFY(handle>=1 && handle<MAX_GEOHANDLE);
  sGeoHandle *gh = &GeoHandle[handle];
  if((what & sGEO_VERTEX) && !(gh->Mode & sGEO_STATVB)) MGeo[handle].Dirty |= sGEO_VERTEX;
  if((what & sGEO_INDEX) && !(gh->Mode & sGEO_STATIB))  MGeo[handle].Dirty |= sGEO_INDEX;
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
  MacGeo *mg = &MGeo[handle];

  if(fp) *fp = 0;
  if(ip) *ip = 0;

  if(upd & sGEO_VERTEX)
  {
    gh->Vertex.Start = 0;
    gh->Vertex.Count = vc;
    GrowBuffer(mg->Vertex,mg->VertexAlloc,sMax(vc,1)*gh->VertexSize);
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
  MacGeo *mg = &MGeo[handle];
  if(vc!=-1) gh->Vertex.Count = vc;
  if(ic!=-1) gh->Index.Count = ic;

  // static buffers get their own Metal buffer, dynamic ones go to the ring at draw time
  if((gh->Locked & sGEO_VERTEX) && (gh->Mode & sGEO_STATVB))
    mg->VB = gh->Vertex.Count ? [Dev newBufferWithBytes:mg->Vertex length:gh->Vertex.Count*gh->VertexSize options:MTLResourceStorageModeShared] : nil;
  if((gh->Locked & sGEO_INDEX) && (gh->Mode & sGEO_STATIB))
    mg->IB = gh->Index.Count ? [Dev newBufferWithBytes:mg->Index length:gh->Index.Count*((gh->Mode & sGEO_IND32B) ? 4 : 2) options:MTLResourceStorageModeShared] : nil;
  gh->Locked = 0;
}

sInt sSystem_::GeoDraw(sInt &handle)
{
  sVERIFY(handle>=1 && handle<MAX_GEOHANDLE);
  sVERIFY(GeoHandle[handle].Mode!=0);
  sGeoHandle *gh = &GeoHandle[handle];
  MacGeo *mg = &MGeo[handle];

  sInt update = mg->Dirty;
  if(gh->Vertex.Count == 0)
    update |= sGEO_VERTEX|sGEO_INDEX;
  if(update)
    return update;

  if(!EnsurePass())
    return 0;
  id<MTLRenderPipelineState> pipe = GetPipeline(gh->FVF);
  if(!pipe)
    return 0;

  // vertices and indices
  id<MTLBuffer> vb = mg->VB, ib = mg->IB;
  size_t vbo = 0, ibo = 0;
  sInt indexSize = (gh->Mode & sGEO_IND32B) ? 4 : 2;
  if(!(gh->Mode & sGEO_STATVB) || !vb)
  {
    void *p = RingAlloc(gh->Vertex.Count*gh->VertexSize,vb,vbo);
    if(!p) return 0;
    sCopyMem(p,mg->Vertex,gh->Vertex.Count*gh->VertexSize);
  }
  if(gh->Index.Count && (!(gh->Mode & sGEO_STATIB) || !ib))
  {
    void *p = RingAlloc(gh->Index.Count*indexSize,ib,ibo);
    if(!p) return 0;
    sCopyMem(p,mg->Index,gh->Index.Count*indexSize);
  }

  SetViewportAndScissor();
  [Enc setRenderPipelineState:pipe];
  [Enc setDepthStencilState:GetDepthState()];
  [Enc setStencilReferenceValue:State[sD3DRS_STENCILREF]&0xff];
  switch(State[sD3DRS_CULLMODE])
  {
  case sD3DCULL_CW:  [Enc setFrontFacingWinding:MTLWindingCounterClockwise]; [Enc setCullMode:MTLCullModeBack]; break;
  case sD3DCULL_CCW: [Enc setFrontFacingWinding:MTLWindingClockwise];        [Enc setCullMode:MTLCullModeBack]; break;
  default:           [Enc setCullMode:MTLCullModeNone]; break;
  }
  [Enc setTriangleFillMode:State[sD3DRS_FILLMODE]==2 ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
  [Enc setVertexBuffer:vb offset:vbo atIndex:0];
  [Enc setVertexBytes:VSConst length:sizeof(VSConst) atIndex:1];
  [Enc setFragmentBytes:PSConst length:sizeof(PSConst) atIndex:0];
  struct { sInt alphaFunc; sF32 alphaRef; } ps;
  ps.alphaFunc = State[sD3DRS_ALPHATESTENABLE] ? (sInt)State[sD3DRS_ALPHAFUNC] : 8;
  ps.alphaRef = (sF32)(State[sD3DRS_ALPHAREF]&255);
  [Enc setFragmentBytes:&ps length:sizeof(ps) atIndex:1];
  for(sInt i=0;i<4;i++)
  {
    [Enc setFragmentTexture:StageTexture(i) atIndex:i];
    [Enc setFragmentSamplerState:GetSampler(i) atIndex:i];
  }

  sInt count = gh->Index.Count ? gh->Index.Count : gh->Vertex.Count;
  MTLPrimitiveType type = MTLPrimitiveTypeTriangle;
  switch(gh->Mode&7)
  {
  case sGEO_POINT:     type = MTLPrimitiveTypePoint; break;
  case sGEO_LINE:      type = MTLPrimitiveTypeLine; break;
  case sGEO_LINESTRIP: type = MTLPrimitiveTypeLineStrip; break;
  case sGEO_TRI:       type = MTLPrimitiveTypeTriangle; break;
  case sGEO_TRISTRIP:  type = MTLPrimitiveTypeTriangleStrip; break;
  case sGEO_QUAD:
    [Enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:gh->Vertex.Count/4*6 indexType:MTLIndexTypeUInt16
      indexBuffer:QuadIB indexBufferOffset:0];
    MacDrawCalls++;
    return 0;
  }
  if(gh->Index.Count)
    [Enc drawIndexedPrimitives:type indexCount:count indexType:indexSize==4 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16
      indexBuffer:ib indexBufferOffset:ibo];
  else if(count)
    [Enc drawPrimitives:type vertexStart:0 vertexCount:count];
  MacDrawCalls++;
  return 0;
}
