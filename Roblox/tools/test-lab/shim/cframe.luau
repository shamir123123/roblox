-- Roblox-accurate CFrame in pure Luau (Lune's CFrame.lookAt flips Z).
-- Layout matches Roblox GetComponents: x, y, z, R00..R22, where the columns are
-- RightVector (R00,R10,R20), UpVector (R01,R11,R21) and -LookVector (R02,R12,R22).
local Vector3 = require("@lune/roblox").Vector3

local CFrame = {}
CFrame.__index = nil -- set below
CFrame.__type = "CFrame"

local mt = {}
mt.__type = "CFrame"

local function make(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
	return setmetatable({ x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 }, mt)
end

local function new(...)
	local n = select("#", ...)
	if n == 0 then return make(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1) end
	local a, b = ...
	if n == 1 then return make(a.X, a.Y, a.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1) end
	if n == 2 then return CFrame.lookAt(a, b) end
	if n == 3 then return make(a, (select(2, ...)), (select(3, ...)), 1, 0, 0, 0, 1, 0, 0, 0, 1) end
	if n == 12 then return make(...) end
	error("CFrame.new: unsupported argument count " .. n)
end
CFrame.new = new

function CFrame.fromMatrix(pos, vx, vy, vz)
	vz = vz or vx:Cross(vy).Unit
	return make(pos.X, pos.Y, pos.Z, vx.X, vy.X, vz.X, vx.Y, vy.Y, vz.Y, vx.Z, vy.Z, vz.Z)
end

function CFrame.lookAt(pos, target, up)
	up = up or Vector3.yAxis
	local f = target - pos
	if f.Magnitude < 1e-9 then return make(pos.X, pos.Y, pos.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1) end
	f = f.Unit
	local r = f:Cross(up)
	if r.Magnitude < 1e-6 then
		-- looking straight along `up`: Roblox falls back to a fixed right axis
		r = f:Cross(Vector3.new(0, 0, 1))
		if r.Magnitude < 1e-6 then r = f:Cross(Vector3.new(1, 0, 0)) end
	end
	r = r.Unit
	local u = r:Cross(f)
	return CFrame.fromMatrix(pos, r, u, -f)
end

local function mul3(a, b)
	-- rotation a * rotation b (row-major a[4..12])
	return a[4]*b[4] + a[5]*b[7] + a[6]*b[10], a[4]*b[5] + a[5]*b[8] + a[6]*b[11], a[4]*b[6] + a[5]*b[9] + a[6]*b[12],
		a[7]*b[4] + a[8]*b[7] + a[9]*b[10], a[7]*b[5] + a[8]*b[8] + a[9]*b[11], a[7]*b[6] + a[8]*b[9] + a[9]*b[12],
		a[10]*b[4] + a[11]*b[7] + a[12]*b[10], a[10]*b[5] + a[11]*b[8] + a[12]*b[11], a[10]*b[6] + a[11]*b[9] + a[12]*b[12]
end

function CFrame.Angles(rx, ry, rz)
	local cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
	local X = make(0, 0, 0, 1, 0, 0, 0, cx, -sx, 0, sx, cx)
	local Y = make(0, 0, 0, cy, 0, sy, 0, 1, 0, -sy, 0, cy)
	local Z = make(0, 0, 0, cz, -sz, 0, sz, cz, 0, 0, 0, 1)
	return X * Y * Z
end
CFrame.fromEulerAnglesXYZ = CFrame.Angles

function CFrame.fromEulerAnglesYXZ(rx, ry, rz)
	local cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
	local X = make(0, 0, 0, 1, 0, 0, 0, cx, -sx, 0, sx, cx)
	local Y = make(0, 0, 0, cy, 0, sy, 0, 1, 0, -sy, 0, cy)
	local Z = make(0, 0, 0, cz, -sz, 0, sz, cz, 0, 0, 0, 1)
	return Y * X * Z
end
CFrame.fromOrientation = CFrame.fromEulerAnglesYXZ

function CFrame.fromAxisAngle(axis, angle)
	local u = axis.Unit
	local c, s = math.cos(angle), math.sin(angle)
	local t = 1 - c
	local x, y, z = u.X, u.Y, u.Z
	return make(0, 0, 0,
		t*x*x + c, t*x*y - s*z, t*x*z + s*y,
		t*x*y + s*z, t*y*y + c, t*y*z - s*x,
		t*x*z - s*y, t*y*z + s*x, t*z*z + c)
end

CFrame.identity = new()

local function toQuat(c)
	local m00, m01, m02, m10, m11, m12, m20, m21, m22 = c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12]
	local tr = m00 + m11 + m22
	local w, x, y, z
	if tr > 0 then
		local s = math.sqrt(tr + 1) * 2
		w = 0.25 * s; x = (m21 - m12) / s; y = (m02 - m20) / s; z = (m10 - m01) / s
	elseif m00 > m11 and m00 > m22 then
		local s = math.sqrt(1 + m00 - m11 - m22) * 2
		w = (m21 - m12) / s; x = 0.25 * s; y = (m01 + m10) / s; z = (m02 + m20) / s
	elseif m11 > m22 then
		local s = math.sqrt(1 + m11 - m00 - m22) * 2
		w = (m02 - m20) / s; x = (m01 + m10) / s; y = 0.25 * s; z = (m12 + m21) / s
	else
		local s = math.sqrt(1 + m22 - m00 - m11) * 2
		w = (m10 - m01) / s; x = (m02 + m20) / s; y = (m12 + m21) / s; z = 0.25 * s
	end
	return w, x, y, z
end

local function fromQuat(px, py, pz, w, x, y, z)
	local n = math.sqrt(w*w + x*x + y*y + z*z)
	w, x, y, z = w / n, x / n, y / n, z / n
	return make(px, py, pz,
		1 - 2*(y*y + z*z), 2*(x*y - z*w), 2*(x*z + y*w),
		2*(x*y + z*w), 1 - 2*(x*x + z*z), 2*(y*z - x*w),
		2*(x*z - y*w), 2*(y*z + x*w), 1 - 2*(x*x + y*y))
end

local methods = {}

function methods.Inverse(c)
	-- transpose rotation, -R^T p
	local x, y, z = c[1], c[2], c[3]
	return make(
		-(c[4]*x + c[7]*y + c[10]*z), -(c[5]*x + c[8]*y + c[11]*z), -(c[6]*x + c[9]*y + c[12]*z),
		c[4], c[7], c[10], c[5], c[8], c[11], c[6], c[9], c[12])
end

function methods.Lerp(a, b, t)
	local aw, ax, ay, az = toQuat(a)
	local bw, bx, by, bz = toQuat(b)
	local dot = aw*bw + ax*bx + ay*by + az*bz
	if dot < 0 then bw, bx, by, bz, dot = -bw, -bx, -by, -bz, -dot end
	local w, x, y, z
	if dot > 0.9995 then
		w, x, y, z = aw + (bw - aw)*t, ax + (bx - ax)*t, ay + (by - ay)*t, az + (bz - az)*t
	else
		local th = math.acos(math.clamp(dot, -1, 1))
		local s = math.sin(th)
		local wa, wb = math.sin((1 - t) * th) / s, math.sin(t * th) / s
		w, x, y, z = aw*wa + bw*wb, ax*wa + bx*wb, ay*wa + by*wb, az*wa + bz*wb
	end
	return fromQuat(a[1] + (b[1] - a[1])*t, a[2] + (b[2] - a[2])*t, a[3] + (b[3] - a[3])*t, w, x, y, z)
end

function methods.VectorToWorldSpace(c, v)
	return Vector3.new(c[4]*v.X + c[5]*v.Y + c[6]*v.Z, c[7]*v.X + c[8]*v.Y + c[9]*v.Z, c[10]*v.X + c[11]*v.Y + c[12]*v.Z)
end
function methods.VectorToObjectSpace(c, v)
	return Vector3.new(c[4]*v.X + c[7]*v.Y + c[10]*v.Z, c[5]*v.X + c[8]*v.Y + c[11]*v.Z, c[6]*v.X + c[9]*v.Y + c[12]*v.Z)
end
function methods.PointToWorldSpace(c, v) return c * v end
function methods.PointToObjectSpace(c, v) return methods.Inverse(c) * v end
function methods.ToWorldSpace(c, o) return c * o end
function methods.ToObjectSpace(c, o) return methods.Inverse(c) * o end
function methods.GetComponents(c) return table.unpack(c, 1, 12) end
methods.components = methods.GetComponents
function methods.ToEulerAnglesXYZ(c)
	local ry = math.asin(math.clamp(c[6], -1, 1))
	local rx = math.atan2(-c[9], c[12])
	local rz = math.atan2(-c[5], c[4])
	return rx, ry, rz
end
function methods.ToEulerAnglesYXZ(c)
	local rx = math.asin(math.clamp(-c[9], -1, 1))
	local ry = math.atan2(c[6], c[12])
	local rz = math.atan2(c[7], c[8])
	return rx, ry, rz
end
methods.ToOrientation = methods.ToEulerAnglesYXZ
function methods.FuzzyEq(a, b, eps)
	eps = eps or 1e-5
	for i = 1, 12 do if math.abs(a[i] - b[i]) > eps then return false end end
	return true
end

mt.__index = function(c, k)
	if k == "Position" or k == "p" then return Vector3.new(c[1], c[2], c[3]) end
	if k == "X" then return c[1] end
	if k == "Y" then return c[2] end
	if k == "Z" then return c[3] end
	if k == "LookVector" or k == "lookVector" then return Vector3.new(-c[6], -c[9], -c[12]) end
	if k == "RightVector" or k == "XVector" then return Vector3.new(c[4], c[7], c[10]) end
	if k == "UpVector" or k == "YVector" then return Vector3.new(c[5], c[8], c[11]) end
	if k == "ZVector" then return Vector3.new(c[6], c[9], c[12]) end
	if k == "Rotation" then return make(0, 0, 0, c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12]) end
	local m = methods[k]
	if m then return m end
	error(tostring(k) .. " is not a valid member of CFrame", 2)
end

mt.__mul = function(a, b)
	if typeof(b) == "Vector3" then
		return Vector3.new(a[4]*b.X + a[5]*b.Y + a[6]*b.Z + a[1], a[7]*b.X + a[8]*b.Y + a[9]*b.Z + a[2], a[10]*b.X + a[11]*b.Y + a[12]*b.Z + a[3])
	end
	local r00, r01, r02, r10, r11, r12, r20, r21, r22 = mul3(a, b)
	return make(
		a[4]*b[1] + a[5]*b[2] + a[6]*b[3] + a[1],
		a[7]*b[1] + a[8]*b[2] + a[9]*b[3] + a[2],
		a[10]*b[1] + a[11]*b[2] + a[12]*b[3] + a[3],
		r00, r01, r02, r10, r11, r12, r20, r21, r22)
end
mt.__add = function(a, v)
	return make(a[1] + v.X, a[2] + v.Y, a[3] + v.Z, a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12])
end
mt.__sub = function(a, v)
	return make(a[1] - v.X, a[2] - v.Y, a[3] - v.Z, a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12])
end
mt.__eq = function(a, b)
	for i = 1, 12 do if a[i] ~= b[i] then return false end end
	return true
end
mt.__tostring = function(c)
	return ("CFrame(%g, %g, %g)"):format(c[1], c[2], c[3])
end

return CFrame
