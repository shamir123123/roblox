--!strict
-- VehicleTypes
-- Vehicle class taxonomy + CollectionService tag scheme shared by the driving
-- systems. A vehicle's class is identified purely by its tag, so new vehicle
-- kinds (buses, emergency, service) can be added later without touching the
-- drivers -- they tag the model and the rules already know what to do.

local CollectionService = game:GetService("CollectionService")

local VehicleTypes = {}

export type VehicleClass = "Car" | "Bus" | "Truck" | "Emergency" | "Service" | "Train"

VehicleTypes.Car       = "Car" :: VehicleClass
VehicleTypes.Bus       = "Bus" :: VehicleClass
VehicleTypes.Truck     = "Truck" :: VehicleClass
VehicleTypes.Emergency = "Emergency" :: VehicleClass
VehicleTypes.Service   = "Service" :: VehicleClass
VehicleTypes.Train     = "Train" :: VehicleClass

VehicleTypes.Order = table.freeze({ "Car", "Bus", "Truck", "Emergency", "Service", "Train" }) :: { VehicleClass }

-- Who may use a bus lane / busway: buses plus the services that share them in real
-- cities. Taxis have no class of their own yet -- they'd ride under Service.
VehicleTypes.BusLaneClasses = table.freeze({ Bus = true, Emergency = true, Service = true }) :: { [string]: boolean }

VehicleTypes.Tag = table.freeze({
	Car       = "Vehicle_Car",
	Bus       = "Vehicle_Bus",
	Truck     = "Vehicle_Truck",
	Emergency = "Vehicle_Emergency",
	Service   = "Vehicle_Service",
	Train     = "Vehicle_Train",
}) :: { [string]: string }

function VehicleTypes.tagFor(class: VehicleClass): string
	return VehicleTypes.Tag[class] or VehicleTypes.Tag.Car
end

-- Reads the vehicle class off a model's CollectionService tags. Untagged models
-- are treated as ordinary cars so legacy spawners keep working unchanged.
function VehicleTypes.classOf(model: Instance): VehicleClass
	for _, class in VehicleTypes.Order do
		if CollectionService:HasTag(model, VehicleTypes.Tag[class]) then
			return class
		end
	end
	return VehicleTypes.Car
end

-- Emergency vehicles may override normal right-of-way / signal behaviour.
function VehicleTypes.canPreempt(class: VehicleClass): boolean
	return class == "Emergency"
end

return VehicleTypes
