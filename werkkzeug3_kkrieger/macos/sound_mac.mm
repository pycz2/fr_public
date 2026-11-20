// This file is distributed under a BSD license. See LICENSE.txt for details.

// Sound for the macOS player: AudioQueue output, the game's sound handler
// (V2 music) and a small software mixer for the sample player, which
// replaces DirectSound buffers and DirectSound3D.

#import <AudioToolbox/AudioToolbox.h>
#include <os/lock.h>

#include "_types.hpp"
#include "_start.hpp"

/****************************************************************************/

static const sInt SampleRate = 44100;
static const sInt QueueFrames = 1024;     // multiple of the handler's alignment (64)
static const sInt QueueBuffers = 3;

static AudioQueueRef Queue;
static os_unfair_lock Lock = OS_UNFAIR_LOCK_INIT;
static sSoundHandler Handler;
static void *HandlerUser;
static sBool Muted;

struct MacVoice
{
  sInt Pos;                       // in sample frames, -1: stopped
  sF32 Volume;                    // linear gain from SamplePlay
  sF32 GainL,GainR;               // current gains, including 3d/pan
  sBool Mode3D;                   // 3d processing enabled (Sample3DParam was called)
  sVector Pos3D;
  sF32 MinDist,MaxDist;
  sInt PlayTime;                  // GetTime() when started, 0: stopped
};

struct MacSample
{
  sS16 *Data;                     // stereo (2d) or mono (3d)
  sInt Length;                    // in frames
  sBool Is3D;
  sInt Count;                     // number of voices
  sInt LRU;
  sInt Uses;
  sInt LenMs;
  MacVoice Voice[sMAXSAMPLEBUFFER];
};

static MacSample Samples[sMAXSAMPLEHANDLE];
static sVector ListenerPos,ListenerRight;
static sF32 ListenerRolloff = 1.0f;

/****************************************************************************/

static void MixVoices(sS16 *out,sInt frames)
{
  for(sInt h=0;h<sMAXSAMPLEHANDLE;h++)
  {
    MacSample *sam = &Samples[h];
    for(sInt v=0;v<sam->Count;v++)
    {
      MacVoice *vo = &sam->Voice[v];
      if(vo->Pos<0)
        continue;
      sInt n = sMin(frames,sam->Length-vo->Pos);
      sF32 gl = vo->GainL, gr = vo->GainR;
      for(sInt i=0;i<n;i++)
      {
        sInt l,r;
        if(sam->Is3D)
          l = r = sam->Data[vo->Pos+i];
        else
        {
          l = sam->Data[(vo->Pos+i)*2+0];
          r = sam->Data[(vo->Pos+i)*2+1];
        }
        sInt ol = out[i*2+0] + (sInt)(l*gl);
        sInt or_ = out[i*2+1] + (sInt)(r*gr);
        out[i*2+0] = sRange<sInt>(ol,32767,-32768);
        out[i*2+1] = sRange<sInt>(or_,32767,-32768);
      }
      vo->Pos += n;
      if(vo->Pos>=sam->Length)
        vo->Pos = -1;
    }
  }
}

static void QueueCallback(void *user,AudioQueueRef q,AudioQueueBufferRef buf)
{
  sS16 *out = (sS16 *) buf->mAudioData;
  sInt frames = buf->mAudioDataBytesCapacity/4;

  os_unfair_lock_lock(&Lock);
  if(Handler && !Muted)
    Handler(out,frames,HandlerUser);
  else
    sSetMem(out,0,frames*4);
  if(!Muted)
    MixVoices(out,frames);
  os_unfair_lock_unlock(&Lock);

  buf->mAudioDataByteSize = frames*4;
  AudioQueueEnqueueBuffer(q,buf,0,0);
}

void MacSoundInit()
{
  AudioStreamBasicDescription fmt;
  sSetMem(&fmt,0,sizeof(fmt));
  fmt.mSampleRate = SampleRate;
  fmt.mFormatID = kAudioFormatLinearPCM;
  fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger|kLinearPCMFormatFlagIsPacked;
  fmt.mChannelsPerFrame = 2;
  fmt.mBitsPerChannel = 16;
  fmt.mBytesPerFrame = 4;
  fmt.mFramesPerPacket = 1;
  fmt.mBytesPerPacket = 4;

  if(AudioQueueNewOutput(&fmt,QueueCallback,0,0,0,0,&Queue)!=noErr)
  {
    Queue = 0;
    return;
  }
  for(sInt i=0;i<QueueBuffers;i++)
  {
    AudioQueueBufferRef buf;
    if(AudioQueueAllocateBuffer(Queue,QueueFrames*4,&buf)==noErr)
      QueueCallback(0,Queue,buf);       // prime with silence or music
  }
  AudioQueueStart(Queue,0);
}

void MacSoundExit()
{
  if(Queue)
  {
    AudioQueueStop(Queue,true);
    AudioQueueDispose(Queue,true);
    Queue = 0;
  }
}

void MacSoundMute(sBool mute)
{
  os_unfair_lock_lock(&Lock);
  Muted = mute;
  os_unfair_lock_unlock(&Lock);
}

/****************************************************************************/

void sSystem_::SetSoundHandler(sSoundHandler hnd,sInt align,void *user)
{
  os_unfair_lock_lock(&Lock);
  Handler = hnd;
  HandlerUser = user;
  os_unfair_lock_unlock(&Lock);
}

sInt sSystem_::SampleAdd(sS16 *data,sInt size,sInt buffers,sInt handle,sBool is3d)
{
  sVERIFY(buffers>=1 && buffers<=sMAXSAMPLEBUFFER);
  if(handle==sINVALID)
  {
    for(sInt i=0;i<sMAXSAMPLEHANDLE;i++)
    {
      if(Samples[i].Count==0)
      {
        handle = i;
        break;
      }
    }
  }
  else
  {
    sVERIFY(handle>=0 && handle<sMAXSAMPLEHANDLE);
    if(Samples[handle].Count!=0)
      handle = sINVALID;
  }
  if(handle==sINVALID)
    return sINVALID;

  MacSample *sam = &Samples[handle];
  sS16 *mem;
  if(is3d)                                  // mono downmix, like the D3D version
  {
    mem = new sS16[size];
    for(sInt i=0;i<size;i++)
      mem[i] = (data[i*2+0] + data[i*2+1]) >> 1;
  }
  else
  {
    mem = new sS16[size*2];
    sCopyMem(mem,data,size*4);
  }

  os_unfair_lock_lock(&Lock);
  sam->Data = mem;
  sam->Length = size;
  sam->Is3D = is3d;
  sam->LRU = 0;
  sam->Uses = 0;
  sam->LenMs = size*1000/SampleRate + 10;
  for(sInt i=0;i<buffers;i++)
  {
    sSetMem(&sam->Voice[i],0,sizeof(MacVoice));
    sam->Voice[i].Pos = -1;
  }
  sam->Count = buffers;
  os_unfair_lock_unlock(&Lock);
  return handle;
}

// DirectSound volumes: the D3D version passes log(volume)*2000 (natural log)
// as hundredths of a decibel, so the real gain is volume^ln(10).
static sF32 D3DGain(sF32 volume)
{
  volume = sRange(volume,1.0f,1e-20f);
  return powf(volume,2.302585f);
}

sInt sSystem_::SamplePlay(sInt handle,sF32 volume,sF32 pan,sInt freq)
{
  sVERIFY(handle>=0 && handle<sMAXSAMPLEHANDLE);
  MacSample *sam = &Samples[handle];
  if(sam->Count<=0)
    return -1;

  os_unfair_lock_lock(&Lock);
  sam->LRU = (sam->LRU+1)%sam->Count;
  MacVoice *vo = &sam->Voice[sam->LRU];
  vo->Pos = 0;
  vo->Volume = D3DGain(volume);
  vo->GainL = vo->GainR = vo->Volume;
  if(!sam->Is3D)                            // pan in decibels, attenuates the other side
  {
    sF32 db = sRange<sF32>(pan,100,-100);
    if(db>0) vo->GainL *= powf(10.0f,-db/20.0f);
    if(db<0) vo->GainR *= powf(10.0f,db/20.0f);
  }
  vo->Mode3D = sFALSE;                      // DS3DMODE_DISABLE until Sample3DParam
  vo->PlayTime = GetTime() | 1;
  sInt uses = ++sam->Uses;
  os_unfair_lock_unlock(&Lock);
  return uses;
}

void sSystem_::Sample3DParam(sInt handle,sInt bufnum,const sVector &pos,const sVector &vel,sF32 minDist,sF32 maxDist)
{
  sVERIFY(handle>=0 && handle<sMAXSAMPLEHANDLE);
  MacSample *sam = &Samples[handle];

  os_unfair_lock_lock(&Lock);
  if(sam->Is3D && sam->Uses - bufnum < sam->Count)   // buffer not reused yet
  {
    MacVoice *vo = &sam->Voice[bufnum % sam->Count];
    if(vo->PlayTime)
    {
      vo->Mode3D = sTRUE;
      vo->Pos3D = pos;
      vo->MinDist = minDist;
      vo->MaxDist = maxDist;
    }
  }
  os_unfair_lock_unlock(&Lock);
}

void sSystem_::Sample3DListener(const sVector &pos,const sVector &vel,const sVector &up,const sVector &fwd,sF32 doppler,sF32 rolloff)
{
  os_unfair_lock_lock(&Lock);
  ListenerPos = pos;
  ListenerRight.Cross3(up,fwd);             // left-handed: right = up x front
  ListenerRight.UnitSafe3();
  ListenerRolloff = rolloff;
  os_unfair_lock_unlock(&Lock);
}

// distance attenuation and panning like DirectSound3D's default mode
void sSystem_::Sample3DCommit()
{
  sInt time = GetTime();

  os_unfair_lock_lock(&Lock);
  for(sInt h=0;h<sMAXSAMPLEHANDLE;h++)
  {
    MacSample *sam = &Samples[h];
    if(!sam->Is3D)
      continue;
    for(sInt v=0;v<sam->Count;v++)
    {
      MacVoice *vo = &sam->Voice[v];
      if(vo->PlayTime && vo->PlayTime + sam->LenMs < time)
        vo->PlayTime = 0;
      if(!vo->PlayTime || !vo->Mode3D)
        continue;

      sVector d;
      d.Sub3(vo->Pos3D,ListenerPos);
      sF32 dist = d.Abs3();
      sF32 att = 1.0f;
      sF32 clamped = sMin(dist,vo->MaxDist);
      if(clamped > vo->MinDist && vo->MinDist>0)
        att = vo->MinDist / (vo->MinDist + ListenerRolloff*(clamped-vo->MinDist));
      sF32 pan = dist>1e-4f ? d.Dot3(ListenerRight)/dist : 0.0f;
      vo->GainL = vo->Volume * att * sMin(1.0f,1.0f-pan);
      vo->GainR = vo->Volume * att * sMin(1.0f,1.0f+pan);
    }
  }
  os_unfair_lock_unlock(&Lock);
}
