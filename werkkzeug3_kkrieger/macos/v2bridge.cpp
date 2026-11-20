// This file is distributed under a BSD license. See LICENSE.txt for details.

// Bridge between the kkrieger player and the C++ version of the V2 synth
// in ../v2. kkrieger was built with an older V2 (_viruz2a.asm, x86 only).
// Its .v2m data is converted to the current synth version with ConvertV2M
// and then played with V2MPlayer. This file is compiled with the V2 headers
// only, because their base types clash with _types.hpp.

#include "types.h"
#include "sounddef.h"
#include "v2mconv.h"
#include "v2mplayer.h"
#include "libv2.h"
#include "v2bridge.h"

#include <string.h>
#include <stdio.h>
#include <new>

// version tables that v2mconv.cpp needs (the same as sdInit() in sounddef.cpp)

int v2version;
int *v2vsizes;
int *v2gsizes;

static void InitVersionTables()
{
  if(v2vsizes)
    return;

  v2version = 0;
  for(int i=0;i<v2nparms;i++)
    if(v2parms[i].version>v2version) v2version = v2parms[i].version;
  for(int i=0;i<v2ngparms;i++)
    if(v2gparms[i].version>v2version) v2version = v2gparms[i].version;

  v2vsizes = new int[v2version+1];
  v2gsizes = new int[v2version+1];
  memset(v2vsizes,0,(v2version+1)*sizeof(int));
  memset(v2gsizes,0,(v2version+1)*sizeof(int));
  for(int i=0;i<v2nparms;i++)
    for(int j=v2version;j>=v2parms[i].version;j--)
      v2vsizes[j]++;
  for(int i=0;i<v2ngparms;i++)
    for(int j=v2version;j>=v2gparms[i].version;j--)
      v2gsizes[j]++;
  for(int i=0;i<=v2version;i++)
    v2vsizes[i] += 1+255*3;
}

// size of a v2m block, walked the same way as the old player's InitBase()

static int V2MSize(const sU8 *start)
{
  const sU8 *d = start;
  sU32 gdnum = *(const sU32 *)(d+8);
  d += 12 + 10*gdnum;
  for(int ch=0;ch<16;ch++)
  {
    sU32 notenum = *(const sU32 *)d; d += 4;
    if(notenum)
    {
      d += 5*notenum;
      sU32 pcnum = *(const sU32 *)d; d += 4 + 4*pcnum;
      sU32 pbnum = *(const sU32 *)d; d += 4 + 5*pbnum;
      for(int cn=0;cn<7;cn++)
      {
        sU32 ccnum = *(const sU32 *)d; d += 4 + 4*ccnum;
      }
    }
  }
  d += 4 + *(const sU32 *)d;   // globals
  d += 4 + *(const sU32 *)d;   // patches
  d += 4 + *(const sU32 *)d;   // speech (always present in kkrieger's data)
  return (int)(d-start);
}

struct V2Bridge
{
  V2MPlayer Player;
  sU8 *Converted;
};

void *V2BridgeNew()
{
  InitVersionTables();
  if(synthGetSize() > 3*1024*1024)        // size of V2MPlayer::m_synth
  {
    fprintf(stderr,"v2bridge: synth state (%u bytes) does not fit into V2MPlayer\n",synthGetSize());
    return 0;
  }
  V2Bridge *b = new V2Bridge;
  b->Player.Init();
  b->Converted = 0;
  return b;
}

static void FreeConverted(V2Bridge *b)
{
  delete[] b->Converted;
  b->Converted = 0;
}

void V2BridgeDelete(void *h)
{
  V2Bridge *b = (V2Bridge *)h;
  if(!b) return;
  b->Player.Close();
  FreeConverted(b);
  delete b;
}

int V2BridgeOpen(void *h,const void *v2m,unsigned samplerate)
{
  V2Bridge *b = (V2Bridge *)h;
  b->Player.Close();
  FreeConverted(b);

  int inlen = V2MSize((const sU8 *)v2m);
  int outlen = 0;
  ConvertV2M((const sU8 *)v2m,inlen,&b->Converted,&outlen);
  if(!b->Converted)
  {
    fprintf(stderr,"v2bridge: cannot convert v2m (%d bytes, version check %d)\n",
      inlen,CheckV2MVersion((const sU8 *)v2m,inlen));
    return 0;
  }
  return b->Player.Open(b->Converted,samplerate) ? 1 : 0;
}

void V2BridgeClose(void *h)
{
  V2Bridge *b = (V2Bridge *)h;
  b->Player.Close();
  FreeConverted(b);
}

void V2BridgePlay(void *h,unsigned time)            { ((V2Bridge *)h)->Player.Play(time); }
void V2BridgeStop(void *h,unsigned fadetime)        { ((V2Bridge *)h)->Player.Stop(fadetime); }
void V2BridgeRender(void *h,float *buf,unsigned len){ ((V2Bridge *)h)->Player.Render(buf,len); }
int V2BridgeIsPlaying(void *h)                      { return ((V2Bridge *)h)->Player.IsPlaying() ? 1 : 0; }
