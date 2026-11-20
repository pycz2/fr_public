// This file is distributed under a BSD license. See LICENSE.txt for details.

// plain C interface to the V2 synth (see v2bridge.cpp)

#ifndef __V2BRIDGE_H__
#define __V2BRIDGE_H__

void *V2BridgeNew();
void V2BridgeDelete(void *h);
int V2BridgeOpen(void *h,const void *v2m,unsigned samplerate);
void V2BridgeClose(void *h);
void V2BridgePlay(void *h,unsigned time);
void V2BridgeStop(void *h,unsigned fadetime);
void V2BridgeRender(void *h,float *buf,unsigned len);
int V2BridgeIsPlaying(void *h);

#endif
