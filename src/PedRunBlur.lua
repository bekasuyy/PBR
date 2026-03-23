local ffi    = require("ffi")
local hook   = require("monethook")
local mem    = require("SAMemory")

local cast     = ffi.cast
local offsetof = ffi.offsetof
local gta      = ffi.load("GTASA")

local OUTLINE_R = 255
local OUTLINE_G = 255
local OUTLINE_B = 255
local OUTLINE_A = 100
local RATIO     = 15

local rpGEOMETRY_MODULATE = 0x40

local RS_TEXTURE_RASTER = 1
local RS_ZTEST_ENABLE   = 6
local RS_SHADE_MODE     = 7
local RS_ZWRITE_ENABLE  = 8
local RS_SRC_BLEND      = 10
local RS_DEST_BLEND     = 11
local RS_VERTEX_ALPHA   = 12
local RS_FOG_ENABLE     = 14

local BLEND_SRC_ALPHA     = 5
local BLEND_INV_SRC_ALPHA = 6
local SHADE_FLAT          = 1
local COMBINE_REPLACE     = 0
local COMBINE_PRECONCAT   = 1

ffi.cdef[[
    int  _Z16RwRenderStateGet13RwRenderStatePv(int state, void* value);
    int  _Z16RwRenderStateSet13RwRenderStatePv(int state, void* value);
    void _Z13RwMatrixScaleP11RwMatrixTagPK5RwV3d15RwOpCombineType(RwMatrix* mat, RwV3D* scale, int combine);
    void _Z16RwFrameTransformP7RwFramePK11RwMatrixTag15RwOpCombineType(RwFrame* frame, RwMatrix* mat, int combine);
    void _Z20RpClumpForAllAtomicsP7RpClumpPFP8RpAtomicS2_PvES3_(RpClump* clump, void*(*cb)(void*, void*), void* data);
    void _Z13RpClumpRenderP7RpClump(RpClump* clump);
    void _Z25RpGeometryForAllMaterialsP10RpGeometryPFP10RpMaterialS2_PvES3_(RpGeometry* geo, void*(*cb)(void*, void*), void* data);
    void* _Z13FindPlayerPedi(int index);
    bool  _ZN6CWorld21GetIsLineOfSightClearERK7CVectorS2_bbbbbbb(vector3d* origin, vector3d* target, bool, bool, bool, bool, bool, bool, bool);
    void  _ZN4CPed6RenderEv(CPed* ped);
]]

local scaleVec = ffi.new("RwV3D")
local scaleMat = ffi.new("RwMatrix")
local colorBuf = ffi.new("RwColor")
local rsBuf    = ffi.new("uint32_t[1]")

local function getPos(entity)
    if entity.pMatrix ~= nil then
        return cast("vector3d*", cast("uintptr_t", entity.pMatrix) + offsetof("matrix", "pos"))
    end
    return cast("vector3d*", entity.nPlacement.vPosition)
end

local function RS_get(state)
    gta._Z16RwRenderStateGet13RwRenderStatePv(state, rsBuf)
    return rsBuf[0]
end

local function RS_set(state, value)
    gta._Z16RwRenderStateSet13RwRenderStatePv(state, cast("void*", value))
end

local cbMaterial = ffi.cast("void*(*)(void*, void*)", function(mat_ptr, data_ptr)
    local mat = cast("RpMaterial*", mat_ptr)
    local col = cast("RwColor*", data_ptr)
    mat.color.r = col.r
    mat.color.g = col.g
    mat.color.b = col.b
    mat.color.a = col.a
    return mat_ptr
end)

local cbSetColor = ffi.cast("void*(*)(void*, void*)", function(atomic_ptr, data_ptr)
    local atomic = cast("RpAtomic*", atomic_ptr)
    local geo = atomic.geometry
    if geo ~= nil then
        geo.flags = bit.bor(geo.flags, rpGEOMETRY_MODULATE)
        gta._Z25RpGeometryForAllMaterialsP10RpGeometryPFP10RpMaterialS2_PvES3_(geo, cbMaterial, data_ptr)
    end
    return atomic_ptr
end)

local cbScale = ffi.cast("void*(*)(void*, void*)", function(atomic_ptr, data_ptr)
    local atomic = cast("RpAtomic*", atomic_ptr)
    local frame  = cast("RwFrame*", atomic.object.object.parent)
    if frame ~= nil then
        gta._Z16RwFrameTransformP7RwFramePK11RwMatrixTag15RwOpCombineType(frame, cast("RwMatrix*", data_ptr), COMBINE_PRECONCAT)
    end
    return atomic_ptr
end)

local function applyScale(clump, scale)
    scaleVec.x = scale; scaleVec.y = scale; scaleVec.z = scale
    gta._Z13RwMatrixScaleP11RwMatrixTagPK5RwV3d15RwOpCombineType(scaleMat, scaleVec, COMBINE_REPLACE)
    gta._Z20RpClumpForAllAtomicsP7RpClumpPFP8RpAtomicS2_PvES3_(clump, cbScale, scaleMat)
end

local white = ffi.new("RwColor", {255, 255, 255, 255})

local function applyColor(clump, r, g, b, a)
    colorBuf.r = r; colorBuf.g = g; colorBuf.b = b; colorBuf.a = a
    gta._Z20RpClumpForAllAtomicsP7RpClumpPFP8RpAtomicS2_PvES3_(clump, cbSetColor, colorBuf)
end

local function DrawOutline(clump, r, g, b, a, scale)
    local oldZWrite = RS_get(RS_ZWRITE_ENABLE)
    local oldSrc    = RS_get(RS_SRC_BLEND)
    local oldDst    = RS_get(RS_DEST_BLEND)
    local oldAlpha  = RS_get(RS_VERTEX_ALPHA)
    local oldZTest  = RS_get(RS_ZTEST_ENABLE)
    local oldFog    = RS_get(RS_FOG_ENABLE)
    local oldShade  = RS_get(RS_SHADE_MODE)

    RS_set(RS_ZWRITE_ENABLE,  0)
    RS_set(RS_ZTEST_ENABLE,   0)
    RS_set(RS_FOG_ENABLE,     0)
    RS_set(RS_SHADE_MODE,     SHADE_FLAT)
    RS_set(RS_SRC_BLEND,      BLEND_SRC_ALPHA)
    RS_set(RS_DEST_BLEND,     BLEND_INV_SRC_ALPHA)
    RS_set(RS_VERTEX_ALPHA,   1)
    RS_set(RS_TEXTURE_RASTER, 0)

    -- render model (scaled up)
    applyScale(clump, scale)
    applyColor(clump, r, g, b, a)
    gta._Z13RpClumpRenderP7RpClump(clump)

    -- restore scale
    applyScale(clump, 1.0 / scale)

    -- restore model, enable ztest, render original model
    gta._Z20RpClumpForAllAtomicsP7RpClumpPFP8RpAtomicS2_PvES3_(clump, cbSetColor, white)

    RS_set(RS_ZWRITE_ENABLE,  1)
    RS_set(RS_ZTEST_ENABLE,   1)
    RS_set(RS_FOG_ENABLE,     oldFog)
    RS_set(RS_SHADE_MODE,     oldShade)
    RS_set(RS_SRC_BLEND,      oldSrc)
    RS_set(RS_DEST_BLEND,     oldDst)
    RS_set(RS_VERTEX_ALPHA,   oldAlpha)
    RS_set(RS_TEXTURE_RASTER, 0)
end

local pedRenderHook
pedRenderHook = hook.new(
    "void(*)(CPed*)",
    function(ped)
        if ped.pRwClump ~= nil then
            local isPlayer = cast("uintptr_t", ped) == cast("uintptr_t", gta._Z13FindPlayerPedi(0))
            local camPos   = getPos(cast("CEntity*", mem.camera))
            local pedPos   = getPos(cast("CEntity*", ped))

            local isClear = gta._ZN6CWorld21GetIsLineOfSightClearERK7CVectorS2_bbbbbbb(
                camPos, pedPos, true, true, true, true, true, false, false
            )

            if isPlayer or isClear then
                local speed = ped.vMoveSpeed:magnitude() * 50.0
                local scale = 1.0 + speed / (100.0 - RATIO)
                DrawOutline(ped.pRwClump, OUTLINE_R, OUTLINE_G, OUTLINE_B, OUTLINE_A, scale)
            end
        end

        pedRenderHook(ped)
    end,
    cast("uintptr_t", cast("void*", gta._ZN4CPed6RenderEv))
)

function main() wait(-1) end
