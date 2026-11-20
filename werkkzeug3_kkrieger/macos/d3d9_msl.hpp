// This file is distributed under a BSD license. See LICENSE.txt for details.

// Direct3D 9 shader bytecode (vs_1_1 + ps_1_1..1_3) to Metal Shading Language

#ifndef __D3D9_MSL_HPP__
#define __D3D9_MSL_HPP__

#include <string>
#include <vector>

// vertex attribute slots used by the generated vertex functions
enum
{
  D3D9MSL_ATTR_POSITION = 0,
  D3D9MSL_ATTR_NORMAL = 1,
  D3D9MSL_ATTR_COLOR0 = 2,
  D3D9MSL_ATTR_COLOR1 = 3,
  D3D9MSL_ATTR_TEXCOORD0 = 4,     // .. 7
  D3D9MSL_ATTR_TANGENT = 8,
  D3D9MSL_ATTR_BINORMAL = 9,
};

// texture type per pixel shader stage, 2 bits each
enum
{
  D3D9MSL_TEX2D = 0,
  D3D9MSL_TEXCUBE = 1,
  D3D9MSL_TEX3D = 2,
};

// attribMask: attribute slots the vertex format provides (others read as 0,0,0,1).
// fragment buffers: 0 = pixel shader constants, 1 = { int alphaFunc; float alphaRef; }
// vertex buffers: 1 = vertex shader constants, stage_in from the vertex descriptor.
bool D3D9ToMSL(const unsigned *vs,const unsigned *ps,unsigned texTypes,
               unsigned attribMask,std::string &out,std::string &error);

#endif
