--// Services
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

--// Packages
local Signal = require(script.Parent.Parent.signal)
local Trove = require(script.Parent.Parent.trove)

--// Types
local Types = require(script.Parent.Types)

--// Item Class
local Item = {}
Item.__index = Item

-- Only one item may be dragged at a time; prevents simultaneous multi-touch drags
-- on separate items and ensures touch rotation targets the correct item.
local _activeDragItem = nil

--[=[
    @class Item
]=]
--[=[
    @prop Position Vector2
    The position of the Item in a grid ItemManager.

    @within Item
]=]
--[=[
    @prop PositionChanged RBXScriptSignal
    @readonly
    @tag Signal
    An event signal that fires every time the Item has it's position changed.

    @within Item
]=]
--[=[
    @prop Size Vector2
    The size of the Item in a grid ItemManager.

    @within Item
]=]
--[=[
    @prop Rotation number
    @readonly
    The current rotation of the item. Use `Item:Rotate()` to edit.

    @within Item
]=]
--[=[
    @prop PotentialRotation number
    @readonly
    The rotation that will be applied if a successful move goes through.

    @within Item
]=]
--[=[
    @prop ItemManager ItemManagerObject?
    @readonly
    The current ItemManger that the Item is in.

    @within Item
]=]
--[=[
    @prop ItemManagerChanged RBXScriptSignal
    @readonly
    @tag Signal
    An event signal that fires every time the Item is moved in a new ItemManager.

    @within Item
]=]
--[=[
    @prop HoveringItemManager ItemManagerObject?
    @readonly
    The ItemManager that the Item is hovering over. ItemManagers need to be linked via TranferLinks to register as a hoverable ItemManager.

    @within Item
]=]
--[=[
    @prop HoveringItemManagerChanged RBXScriptSignal
    @readonly
    @tag Signal
    An event signal that fires every time the Item is hovering over a new ItemManager.

    @within Item
]=]
--[=[
    @prop MoveMiddleware ((movedItem: Item, newGridPosition: Vector2, lastItemManager: ItemManager, newItemManager: ItemManager) -> boolean)?
    A callback function where you can do additional move checks. The Item will be automatically moved back if the callback function returns false.

    @within Item
]=]

--[=[
    Creates a new Item object.

    @within Item
]=]
function Item.new(properties: Types.ItemProperties): Types.ItemObject
	local self = setmetatable({}, Item)
	self._trove = Trove.new()
	self._itemManagerTrove = self._trove:Add(Trove.new())
	self._draggingTrove = self._trove:Add(Trove.new())

	self.Assets = properties.Assets or {}
	if self.Assets.Item == nil then
		self.Assets.Item = self:_createDefaultItemAsset()
	end

	self.Position = properties.Position or Vector2.zero
	self.LastItemManagerParentAbsolutePosition = Vector2.zero
	self.PositionChanged = Signal.new()
	self.Size = properties.Size or Vector2.new(2, 2)
	self.Rotation = properties.Rotation or 0
	self.PotentialRotation = self.Rotation

	self._tweens = {
		Transparency = {},
		GhostTransparency = {}
	}

	self.ItemElement = self:_generateItemElement()
	self.GhostElement = nil
	self._ghostVisualRotation = 0
	self._dragStartRotation = 0
	self._mouseToCenterOffset = Vector2.zero

	self.ItemManager = nil
	self.ItemManagerChanged = Signal.new()
	self.HoveringItemManager = nil
	self.HoveringItemManagerChanged = Signal.new()

	self.MoveMiddleware = properties.MoveMiddleware
	self.RenderMiddleware = properties.RenderMiddleware

	self.IsDraggable = true
	self.IsDragging = false
	self._isDropping = false
	self._lastDragScreenPosition = Vector2.zero

	self.RotateKeyCode = Enum.KeyCode.R
	self.GamepadRotateKeyCode = Enum.KeyCode.ButtonR1
	self.ShowRotateButton = UserInputService.TouchEnabled

	self.DragThreshold = properties.DragThreshold or 0
	self.Clicked = Signal.new()
	self._pendingDrag = false
	self._dragStartScreenPos = Vector2.zero

	self.Metadata = properties.Metadata or {}

	-- Remove item from current ItemManager when item gets destroyed
	self._trove:Add(function()
		if self.ItemManager then
			self.ItemManager:RemoveItem(self)
		end
		if self.GhostElement then
			self.GhostElement:Destroy()
			self.GhostElement = nil
		end
	end)
	self._trove:Add(self.Clicked)

	-- Apply sizing when the item's ItemManager changes
	self._trove:Add(self.ItemManagerChanged:Connect(function(itemManager: Types.ItemManagerObject?, useTween: boolean?)
		self._itemManagerTrove:Clean()

		if self.ItemManager then
			self.LastItemManagerParentAbsolutePosition = self.ItemManager.GuiElement.Parent.AbsolutePosition
		end

		self.ItemManager = itemManager

		if self.ItemManager ~= nil then
			self.ItemElement.Visible = self.ItemManager.Visible

			local test = self.ItemManager.GuiElement.Parent.AbsolutePosition - self.LastItemManagerParentAbsolutePosition
			self.ItemElement.Position = UDim2.fromOffset(self.ItemElement.Position.X.Offset - test.X, self.ItemElement.Position.Y.Offset - test.Y)

			self:_updateItemToItemManagerDimentions(true, true, useTween, useTween)

			self._itemManagerTrove:Add(self.ItemManager.GuiElement:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
				self:_updateItemToItemManagerDimentions(true, false, false, false)
			end))
			self._itemManagerTrove:Add(self.ItemManager.GuiElement:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
				self:_updateItemToItemManagerDimentions(true, true, false, false)
			end))

			self._itemManagerTrove:Add(self.ItemManager.VisibilityChanged:Connect(function(isVisible)
				self.ItemElement.Visible = isVisible
			end))

			self.ItemElement.Parent = self.ItemManager.GuiElement.Parent
		else
			self.ItemElement.Parent = nil
		end
	end))

	-- Update the cursor pivot when the item gets resized
	self._trove:Add(self.ItemElement:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if self.IsDragging then
			self:_updateDraggingPosition(self._lastDragScreenPosition)
		end
	end))

	-- Set up UIDragDetector: parent to InteractionButton (drag handle) if present, otherwise to ItemElement
	local dragDetectorParent = self.ItemElement:FindFirstChild("InteractionButton", true) or self.ItemElement
	self._dragDetector = self._trove:Add(Instance.new("UIDragDetector"))
	self._dragDetector.DragStyle = Enum.UIDragDetectorDragStyle.TranslatePlane
	self._dragDetector.ResponseStyle = Enum.UIDragDetectorResponseStyle.CustomOffset
	self._dragDetector.Parent = dragDetectorParent

	self._highlight = nil
	self._trove:Add(self._dragDetector.DragStart:Connect(function(inputPosition: Vector2)
		-- Check if item is in an ItemManager, if there is then start dragging
		if self.ItemManager ~= nil and self.IsDraggable and _activeDragItem == nil then
			_activeDragItem = self
			self.IsDraggable = false

			local screenPosition = Vector2.new(inputPosition.X, inputPosition.Y)
			self._lastDragScreenPosition = screenPosition
			self._dragStartScreenPos = screenPosition

			-- When DragThreshold > 0, defer full drag setup until cursor exceeds threshold
			if self.DragThreshold > 0 then
				self._pendingDrag = true
				return
			end

			self:_commitDragStart(screenPosition)
		end
	end))

	self._trove:Add(self._dragDetector.DragContinue:Connect(function(inputPosition: Vector2)
		if self.ItemManager == nil then return end
		local screenPosition = Vector2.new(inputPosition.X, inputPosition.Y)
		self._lastDragScreenPosition = screenPosition

		-- Pending drag: check if threshold exceeded before committing to full drag
		if self._pendingDrag then
			if (screenPosition - self._dragStartScreenPos).Magnitude >= self.DragThreshold then
				self._pendingDrag = false
				self:_commitDragStart(self._dragStartScreenPos)
				-- Fall through to normal DragContinue logic with the current position
			else
				return
			end
		end

		if self.IsDragging == true then

			-- Determine which non-source ItemManager (if any) the cursor is inside.
			-- Uses cursor point-in-rect rather than ItemElement overlap to avoid
			-- size-change oscillation when the ghost morphs between cell sizes.
			local bestManager = nil
			if next(self.ItemManager.ConnectedTransferLinks) ~= nil then
				for _, transferLink in pairs(self.ItemManager.ConnectedTransferLinks) do
					for _, manager in ipairs(transferLink.ConnectedItemManagers) do
						if manager ~= self.ItemManager and manager.Visible then
							local p = manager.GuiElement.AbsolutePosition
							local s = manager.GuiElement.AbsoluteSize
							if screenPosition.X >= p.X and screenPosition.X <= p.X + s.X
								and screenPosition.Y >= p.Y and screenPosition.Y <= p.Y + s.Y then
								bestManager = manager
								break
							end
						end
					end
					if bestManager then break end
				end
			end

			-- Update hover state when it changes: entering a new manager, leaving one, or returning to source
			if bestManager ~= self.HoveringItemManager then
				self.HoveringItemManager = bestManager
				self.HoveringItemManagerChanged:Fire(self.HoveringItemManager)

				local targetManager = bestManager or self.ItemManager
				self._highlight:SetItemManager(100, targetManager)
				self:_updateItemToItemManagerDimentions(false, true, false, true, targetManager)
			end

			-- Update ghost position and collision preview
			self:_updateDraggingPosition(screenPosition)

			-- Update rotate button position if present
			if self._rotateButton then
				local parentAbsPos = self._rotateButton.Parent and self._rotateButton.Parent.AbsolutePosition or Vector2.zero
				local ghostCenter = screenPosition - self._mouseToCenterOffset
				local sizeY = self.ItemElement.Size.Y.Offset > 0 and self.ItemElement.Size.Y.Offset or self.ItemElement.AbsoluteSize.Y
				self._rotateButton.Position = UDim2.fromOffset(
					ghostCenter.X - parentAbsPos.X,
					ghostCenter.Y + sizeY / 2 + 8 - parentAbsPos.Y
				)
			end
		end
	end))

	self._trove:Add(self._dragDetector.DragEnd:Connect(function(inputPosition: Vector2)
		-- Pending drag: threshold was never exceeded — treat as a click
		if self._pendingDrag then
			self._pendingDrag = false
			self.IsDraggable = true
			if _activeDragItem == self then
				_activeDragItem = nil
			end
			self.Clicked:Fire()
			return
		end

		if self.IsDragging == true and self.ItemManager ~= nil then
			if self._isDropping then return end
			self._isDropping = true
			self.IsDragging = false

			local screenPosition = Vector2.new(inputPosition.X, inputPosition.Y)

			-- Ensure touch gesture state is cleared on drop
			self._touchGestureActive = false
			self._touchPreviewDelta = 0

			-- Check if the item is colliding or out of bounds, if not add the item to the itemManager
			local currentItemManager = self.HoveringItemManager or self.ItemManager

			-- Compute drop position using center-based math (matches ghost visual position)
			local sizeX = self.ItemElement.Size.X.Offset > 0 and self.ItemElement.Size.X.Offset or self.ItemElement.AbsoluteSize.X
			local sizeY = self.ItemElement.Size.Y.Offset > 0 and self.ItemElement.Size.Y.Offset or self.ItemElement.AbsoluteSize.Y
			local ghostCenter = screenPosition - self._mouseToCenterOffset
			local itemTopLeft = ghostCenter - Vector2.new(sizeX / 2, sizeY / 2)

			local gridPos = currentItemManager:GetItemManagerPositionFromAbsolutePosition(itemTopLeft, self.Size, self.PotentialRotation)
			local isColliding = currentItemManager:IsColliding(self, { self }, gridPos, self.PotentialRotation)
			local isInBounds = currentItemManager:IsRegionInBounds(gridPos, self.Size, self.PotentialRotation)

			local success = false

			if isColliding == false and isInBounds == true then
				-- Get new ItemManager, is nil if no new ItemManager is found
				local newItemManager = nil
				if self.HoveringItemManager and self.HoveringItemManager ~= self.ItemManager then
					newItemManager = self.HoveringItemManager
				end

				-- Check for middleware and if it allows item move
				local middlewareReturn = nil
				if self.MoveMiddleware then
					middlewareReturn = self.MoveMiddleware(self, gridPos, self.PotentialRotation, self.ItemManager, newItemManager)
				end

				-- Check the receiving ItemManager's Filter and MoveMiddleware
				local receivingItemManager = newItemManager or self.ItemManager
				if middlewareReturn ~= false and receivingItemManager.Filter and receivingItemManager.Filter(self) == false then
					middlewareReturn = false
				end
				if middlewareReturn ~= false and receivingItemManager.MoveMiddleware then
					if receivingItemManager.MoveMiddleware(self, gridPos, self.PotentialRotation, self.ItemManager, newItemManager) == false then
						middlewareReturn = false
					end
				end

				if middlewareReturn == true or middlewareReturn == nil then
					-- Move item
					success = true
					self._wasTransferred = newItemManager ~= nil
					self.Position = gridPos
					self.PositionChanged:Fire(gridPos)
					self.Rotation = self.PotentialRotation

					-- Switch ItemManager if the item was hovering above one
					if newItemManager then
						self:SetItemManager(self.HoveringItemManager)
					end
				end
			end

			if not success then
				self.PotentialRotation = self.Rotation
			end

			self.HoveringItemManager = nil
			self.HoveringItemManagerChanged:Fire(self.HoveringItemManager)

			-- Update item positioning to current itemManager instantly (so the invisible math runs flawlessly in background)
			self:_updateItemToItemManagerDimentions(true, true, false, false)

			if self.GhostElement then
				-- Tween the ghost into the target slot
				local targetManager = self.ItemManager
				local itemManagerOffset = targetManager:GetOffset(self.Rotation)
				local sizeScale = targetManager:GetSizeScale()

				local targetAbsTopLeft = Vector2.new(
					self.Position.X * sizeScale.X + itemManagerOffset.X,
					self.Position.Y * sizeScale.Y + itemManagerOffset.Y
				)

				-- Center of the slot region in absolute coords
				local slotAbsSize = targetManager:GetAbsoluteSizeFromItemSize(self.Size, self.Rotation)
				local targetCenter = targetAbsTopLeft + slotAbsSize / 2

				local dropScreenGui = targetManager.GuiElement:FindFirstAncestorOfClass("ScreenGui")
				local parentAbsPos = dropScreenGui and dropScreenGui.AbsolutePosition or Vector2.zero
				local targetCenterPos = UDim2.fromOffset(targetCenter.X - parentAbsPos.X, targetCenter.Y - parentAbsPos.Y)

				-- Ghost frame base size = AABB of item at self.Rotation in the target ItemManager
				local ghostFrameSize = targetManager:GetAbsoluteSizeFromItemSize(self.Size, self.Rotation)
				local targetSize = UDim2.fromOffset(ghostFrameSize.X, ghostFrameSize.Y)

				if self._tweens.GhostRotation then
					self._tweens.GhostRotation:Cancel()
					self._tweens.GhostRotation = nil
				end

				-- Snap ghost to its final accumulated rotation so it keeps the correct visual orientation during the drop tween.
				-- If the frame is rotated by an odd quarter-turn, swap frame tween dimensions so the displayed AABB
				-- remains aligned with the final placed orientation.
				local dropGhostRotation = (self._ghostAccumulatedRot or 0)
				self.GhostElement.Rotation = dropGhostRotation

				local quarterTurns = math.floor(math.abs(dropGhostRotation / 90) + 0.5)
				local isOddQuarterTurn = (quarterTurns % 2) == 1
				local dropFrameTargetSize = targetSize
				if isOddQuarterTurn then
					dropFrameTargetSize = UDim2.fromOffset(targetSize.Y.Offset, targetSize.X.Offset)
				end

				-- Snap size immediately; for cross-manager drops (e.g. grid→hotbar slot)
				-- also snap the position so the ghost doesn't animate to the wrong manager.
				self.GhostElement.Size = dropFrameTargetSize
				self._ghostAccumulatedRot = 0

				if success and self._wasTransferred then
					-- Cross-manager drop: snap ghost to slot immediately, no tween
					self.GhostElement.Position = targetCenterPos
				else
					local dropTweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
					TweenService:Create(self.GhostElement, dropTweenInfo, {
						Position = targetCenterPos,
					}):Play()
				end

				-- Wait to finish snapping to grid before revealing the real item
				local wasTransferred = self._wasTransferred
				task.delay(0.2, function()
					if self.GhostElement then
						self.GhostElement:Destroy()
						self.GhostElement = nil
					end
					-- Only reveal ItemElement for same-manager drops; cross-manager transfers
					-- let the receiving ItemManager's handler control visibility.
					if not wasTransferred then
						self:_tweenTransparency(0, 0.15, self.ItemElement, self._tweens.Transparency)
					end
				end)
			else
				if not self._wasTransferred then
					self:_tweenTransparency(0, 0.15, self.ItemElement, self._tweens.Transparency)
				end
			end

			self._rotateButton = nil
			self.ItemElement.ZIndex -= 1
			self._draggingTrove:Clean()
			self._isDropping = false
			self.IsDraggable = true
			if _activeDragItem == self then
				_activeDragItem = nil
			end
		end
	end))

	if self.RenderMiddleware then
		self.RenderMiddleware(self.ItemElement)
	end

	return self
end

--[=[
    @private
    Performs the full drag start setup: ghost creation, transparency, highlights, input hooks.
    Called immediately from DragStart when DragThreshold == 0, or deferred from DragContinue
    when the threshold is exceeded.

    @within Item
]=]
function Item:_commitDragStart(screenPosition: Vector2)
	self.IsDragging = true

	-- Clear any previous ghost if dragging is interrupted instantly
	if self.GhostElement then
		self.GhostElement:Destroy()
		self.GhostElement = nil
	end
	self:_tweenTransparency(0, 0, self.ItemElement, self._tweens.Transparency)

	-- Get cursor pivot to item center
	local itemStart = self.ItemElement.AbsolutePosition
	local itemSize = self.ItemElement.AbsoluteSize
	local itemCenter = itemStart + itemSize / 2
	self._mouseToCenterOffset = screenPosition - itemCenter

	-- Generate ghost clone anchored at its center so it rotates in place
	self.GhostElement = self.ItemElement:Clone()
	self.GhostElement.Name = "GhostElement"
	self.GhostElement.AnchorPoint = Vector2.new(0.5, 0.5)
	self.GhostElement.Size = UDim2.fromOffset(itemSize.X, itemSize.Y)
	self._ghostAccumulatedRot = 0  -- running total so tween always goes clockwise
	self._ghostVisualRotation = 0
	self._dragStartRotation = self.Rotation -- used to calculate relative rotation tween on drop

	-- Remove any cloned UIDragDetector from ghost so it doesn't interfere
	for _, desc in self.GhostElement:GetDescendants() do
		if desc:IsA("UIDragDetector") then
			desc:Destroy()
		end
	end

	-- Re-parent Ghost to top-level ScreenGui so it is not clipped.
	-- ItemElement stays in its original parent (invisible) to preserve the UIDragDetector session.
	local screenGui = self.ItemManager.GuiElement:FindFirstAncestorOfClass("ScreenGui")
	if screenGui then
		self.GhostElement.Parent = screenGui
	end

	self.GhostElement.ZIndex = self.ItemElement.ZIndex + 1

	-- Make the real item invisible instantly, but keep it active for math and grid bounds
	self:_tweenTransparency(1, 0, self.ItemElement, self._tweens.Transparency)
	-- Make the Ghost slightly transparent for the classic dragging look
	self:_tweenTransparency(0.5, 0.2, self.GhostElement, self._tweens.GhostTransparency)

	self.ItemElement.ZIndex += 1

	-- Keyboard and gamepad rotation
	self._draggingTrove:Add(UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent == false then
			if (input.KeyCode == self.RotateKeyCode or input.KeyCode == self.GamepadRotateKeyCode) and not self._isDropping then
				self:Rotate(1)
			end
		end
	end))

	-- Touch gesture rotation: ghost visually follows the gesture angle directly
	-- (TouchRotate.rotation is total angle since gesture start, not a per-frame delta).
	-- Collision preview updates in discrete 90° steps; ghost snaps on release.
	self._touchGestureActive = false
	self._touchGestureBase = self._ghostAccumulatedRot or 0  -- ghost angle at start of this gesture
	self._touchPreviewDelta = 0                               -- how many quarter-turns we've previewed
	self._draggingTrove:Add(UserInputService.TouchRotate:Connect(function(_touchPositions, rotation, _velocity, state, _gameProcessed)
		-- Do not guard on gameProcessed: UIDragDetector marks the primary drag touch as
		-- processed, which would falsely block the secondary-finger rotation gesture.
		if _activeDragItem ~= self then return end
		if self._isDropping then return end

		-- Capture base angle at the very start of each gesture segment
		if not self._touchGestureActive then
			self._touchGestureActive = true
			self._touchGestureBase = self._ghostAccumulatedRot or 0
			self._touchPreviewDelta = 0
		end

		local gestureAngle = math.deg(rotation) -- total angle since gesture started
		local visualRot = self._touchGestureBase + gestureAngle

		-- Set ghost directly so it follows the finger smoothly
		if self.GhostElement then
			if self._tweens.GhostRotation then
				self._tweens.GhostRotation:Cancel()
				self._tweens.GhostRotation = nil
			end
			self.GhostElement.Rotation = visualRot
		end

		-- Update collision preview in discrete 90° steps (Rotate() is guarded to skip ghost tween during touch)
		local newDelta = math.round(gestureAngle / 90)
		local step = newDelta - self._touchPreviewDelta
		if step ~= 0 then
			self._touchPreviewDelta = newDelta
			self:Rotate(step)
			-- Re-assert smooth visual angle since Rotate() may have touched the ghost
			if self.GhostElement then
				if self._tweens.GhostRotation then
					self._tweens.GhostRotation:Cancel()
					self._tweens.GhostRotation = nil
				end
				self.GhostElement.Rotation = visualRot
			end
		end

		if state == Enum.UserInputState.End then
			self._touchGestureActive = false
			self._touchPreviewDelta = 0
			-- Tween ghost to the final snapped angle (_ghostAccumulatedRot set by Rotate() calls above)
			if self.GhostElement then
				if self._tweens.GhostRotation then
					self._tweens.GhostRotation:Cancel()
					self._tweens.GhostRotation = nil
				end
				self._tweens.GhostRotation = TweenService:Create(self.GhostElement, TweenInfo.new(0.15, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), {
					Rotation = self._ghostAccumulatedRot
				})
				self._tweens.GhostRotation:Play()
			end
		end
	end))

	-- Optional on-screen rotate button for touch devices
	if self.ShowRotateButton then
		local rotateButton = self._draggingTrove:Add(Instance.new("ImageButton"))
		rotateButton.Name = "RotateButton"
		rotateButton.Image = "rbxassetid://6031091004" -- rotate icon
		rotateButton.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
		rotateButton.BackgroundTransparency = 0.3
		rotateButton.Size = UDim2.fromOffset(40, 40)
		rotateButton.AnchorPoint = Vector2.new(0.5, 0)
		rotateButton.ZIndex = self.ItemElement.ZIndex + 2
		self._rotateButton = rotateButton

		local rotateCorner = Instance.new("UICorner")
		rotateCorner.CornerRadius = UDim.new(0, 8)
		rotateCorner.Parent = rotateButton

		local rotateScreenGui = self.ItemManager.GuiElement:FindFirstAncestorOfClass("ScreenGui")
		if rotateScreenGui then
			rotateButton.Parent = rotateScreenGui
		end

		self._draggingTrove:Add(rotateButton.Activated:Connect(function()
			if self.IsDragging and not self._isDropping then
				self:Rotate(1)
			end
		end))
	end

	-- Create drop highlight
	local highlightSize = self.Size
	if self.PotentialRotation % 2 == 1 then
		highlightSize = Vector2.new(self.Size.Y, self.Size.X)
	end

	local gridPos = self.ItemManager:GetItemManagerPositionFromAbsolutePosition(self.ItemElement.AbsolutePosition, self.Size, self.PotentialRotation)
	self._highlight = self._draggingTrove:Add(self.ItemManager:CreateHighlight(100, gridPos, highlightSize, Color3.new(1, 1, 1)))

	self:_updateItemToItemManagerDimentions(false, true, false, true)

	-- Update positioning
	self:_updateDraggingPosition(screenPosition)
end

--[=[
    @private
    Used to create the default Item GUI asset if the user hasn't specified one.

    @within Item
]=]
function Item:_createDefaultItemAsset(): Frame
	local itemElement = Instance.new("Frame")
	itemElement.Name = "ItemElement"
	itemElement.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	itemElement.BorderSizePixel = 0
	itemElement.Size = UDim2.fromOffset(140, 140)
	itemElement.ZIndex = 2

	local imageContainer = Instance.new("CanvasGroup")
	imageContainer.Name = "ImageContainer"
	imageContainer.BackgroundTransparency = 1
	imageContainer.BorderSizePixel = 0
	imageContainer.Size = UDim2.fromScale(1, 1)
	imageContainer.Parent = itemElement

	local image = Instance.new("ImageLabel")
	image.Name = "Image"
	image.Image = ""
	image.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	image.BackgroundTransparency = 1
	image.BorderSizePixel = 0
	image.ScaleType = Enum.ScaleType.Fit
	image.AnchorPoint = Vector2.new(0.5, 0.5)
	image.Position = UDim2.fromScale(0.5, 0.5)
	image.Size = UDim2.fromScale(1, 1)
	image.Parent = imageContainer

	local interactionButton = Instance.new("TextButton")
	interactionButton.Name = "InteractionButton"
	interactionButton.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json")
	interactionButton.Text = ""
	interactionButton.TextColor3 = Color3.fromRGB(0, 0, 0)
	interactionButton.TextSize = 14
	interactionButton.TextTransparency = 1
	interactionButton.AutoButtonColor = false
	interactionButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	interactionButton.BackgroundTransparency = 1
	interactionButton.Size = UDim2.fromScale(1, 1)
	interactionButton.Parent = itemElement

	local uICorner = Instance.new("UICorner")
	uICorner.Name = "UICorner"
	uICorner.CornerRadius = UDim.new(0, 10)
	uICorner.Parent = itemElement

	return itemElement
end

--[=[
    @private
    Clones the specified Item GUI asset in the `Item.Assets.Item` property.

    @within Item
]=]
function Item:_generateItemElement()
	local newItem = self._trove:Add(self.Assets.Item:Clone())
	if self.ItemManager then
		newItem.Visible = self.ItemManager.Visible
	end

	return newItem
end

--[=[
    @private
    Updates the Item's GUI element position to align with the mouse position.

    @within Item
]=]
function Item:_updateDraggingPosition(screenPosition: Vector2)
	if self._tweens.Position then
		self._tweens.Position:Cancel()
		self._tweens.Position = nil
	end

	local parentAbsolutePosition = self.ItemElement.Parent and self.ItemElement.Parent.AbsolutePosition or Vector2.zero

	-- Use Size.Offset for immediate values (AbsoluteSize is stale after rotation)
	local sizeX = self.ItemElement.Size.X.Offset > 0 and self.ItemElement.Size.X.Offset or self.ItemElement.AbsoluteSize.X
	local sizeY = self.ItemElement.Size.Y.Offset > 0 and self.ItemElement.Size.Y.Offset or self.ItemElement.AbsoluteSize.Y

	-- Ghost center follows cursor with fixed offset; derive item top-left from center
	local ghostCenter = screenPosition - self._mouseToCenterOffset
	local itemTopLeft = ghostCenter - Vector2.new(sizeX / 2, sizeY / 2)

	self.ItemElement.Position = UDim2.fromOffset(itemTopLeft.X - parentAbsolutePosition.X, itemTopLeft.Y - parentAbsolutePosition.Y)

	-- Ghost is anchored at (0.5, 0.5) so position it at the center.
	-- Ghost may be reparented to ScreenGui (different parent than ItemElement), so use its own parent position.
	if self.GhostElement then
		local ghostParentPos = self.GhostElement.Parent and self.GhostElement.Parent.AbsolutePosition or Vector2.zero
		self.GhostElement.Position = UDim2.fromOffset(
			ghostCenter.X - ghostParentPos.X,
			ghostCenter.Y - ghostParentPos.Y
		)
	end

	-- Collision check uses the ghost's visual top-left position
	local currentItemManager = self.HoveringItemManager or self.ItemManager
	local gridPos = currentItemManager:GetItemManagerPositionFromAbsolutePosition(itemTopLeft, self.Size, self.PotentialRotation)
	self._highlight.Position = gridPos
	-- Keep highlight size in sync with current item Size (may change externally after drag starts)
	self._highlight.Size = if self.PotentialRotation % 2 == 1 then Vector2.new(self.Size.Y, self.Size.X) else self.Size

	local isColliding = currentItemManager:IsColliding(self, { self }, gridPos, self.PotentialRotation)
	if isColliding == true then
		self._highlight.Color = Color3.new(1, 0, 0)
	else
		self._highlight.Color = Color3.new(1, 1, 1)
	end
end

--[=[
    @private
    Recursively changes transparency of the ItemElement tree to mimic CanvasGroup behaviour.

    @within Item
]=]
function Item:_tweenTransparency(transparencyTarget: number, duration: number, targetElement: GuiObject?, tweenList: table?)
	targetElement = targetElement or self.ItemElement
	tweenList = tweenList or self._tweens.Transparency

	if tweenList and type(tweenList) == "table" then
		for _, tween in pairs(tweenList) do
			tween:Cancel()
		end
		table.clear(tweenList)
	end

	local function tweenProperty(instance, propertyName)
		local originalName = "Original_" .. propertyName
		local original = instance:GetAttribute(originalName)
		if original == nil then
			-- Safety check, occasionally objects get destroyed
			if not instance.Parent then return end

			original = instance[propertyName]
			instance:SetAttribute(originalName, original)
		end

		-- Simple group transparency mapping
		local finalTransparency = original + (1 - original) * transparencyTarget
		if transparencyTarget == 0 then finalTransparency = original end
		if transparencyTarget == 1 then finalTransparency = 1 end -- Full invisibility clamp

		if duration > 0 then
			local t = TweenService:Create(instance, TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {[propertyName] = finalTransparency})
			if tweenList then table.insert(tweenList, t) end
			t:Play()
		else
			instance[propertyName] = finalTransparency
		end
	end

	local function tweenRecursive(instance)
		if instance:IsA("GuiObject") and not instance:IsA("CanvasGroup") then
			tweenProperty(instance, "BackgroundTransparency")
			if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
				tweenProperty(instance, "ImageTransparency")
			elseif instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
				tweenProperty(instance, "TextTransparency")
				tweenProperty(instance, "TextStrokeTransparency")
			elseif instance:IsA("UIStroke") then
				tweenProperty(instance, "Transparency")
			end
		elseif instance:IsA("UIStroke") then
			tweenProperty(instance, "Transparency")
		end

		for _, child in ipairs(instance:GetChildren()) do
			tweenRecursive(child)
		end
	end

	tweenRecursive(targetElement)
end

--[=[
    @private
    Updates the Item's GUI element size and position to align with the new ItemManager.

    @within Item
]=]
function Item:_updateItemToItemManagerDimentions(applyPosition: boolean?, applySize: boolean?, usePositionTween: boolean?, useSizeTween: boolean?, itemManager: Types.ItemManagerObject?)   
	local selectedItemManager = itemManager or self.ItemManager

	-- If the GuiElement has no absolute size yet (ancestor is hidden or ScreenGui is
	-- disabled), skip the update. The AbsoluteSize property-changed listener already
	-- connected above will re-run this function once the layout becomes available.
	if selectedItemManager.GuiElement.AbsoluteSize == Vector2.zero then
		return
	end

	if applyPosition then
		local itemManagerOffset = selectedItemManager:GetOffset(self.Rotation)
		local sizeScale = selectedItemManager:GetSizeScale()
		local elementPosition = UDim2.fromOffset(self.Position.X * sizeScale.X + itemManagerOffset.X - selectedItemManager.GuiElement.Parent.AbsolutePosition.X, self.Position.Y * sizeScale.Y + itemManagerOffset.Y - selectedItemManager.GuiElement.Parent.AbsolutePosition.Y)

		if self._tweens.Position then
			self._tweens.Position:Cancel()
			self._tweens.Position = nil
		end

		if usePositionTween then
			self._tweens.Position = TweenService:Create(self.ItemElement, TweenInfo.new(0.25, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), {Position = elementPosition})
			self._tweens.Position:Play()
		else
			self.ItemElement.Position = elementPosition
		end
	end

	if applySize then
		local currentRot = self.Rotation
		if self.IsDragging and self.PotentialRotation then
			currentRot = self.PotentialRotation
		end

		local absoluteElementSize = selectedItemManager:GetAbsoluteSizeFromItemSize(self.Size, currentRot)
		local elementSize = UDim2.fromOffset(absoluteElementSize.X, absoluteElementSize.Y)

		if self._tweens.Size then
			self._tweens.Size:Cancel()
			self._tweens.Size = nil
		end

		if useSizeTween then
			self._tweens.Size = TweenService:Create(self.ItemElement, TweenInfo.new(0.25, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), { Size = elementSize })
			self._tweens.Size:Play()
		else
			self.ItemElement.Size = elementSize
		end

		-- Ghost frame size is based on self.Rotation (base rotation), not PotentialRotation.
		-- The frame's Rotation property (tweened by Rotate()) handles the visual spin.
		-- Using the base-rotation AABB here prevents double-encoding the orientation.
		if self.GhostElement then
			local ghostAbsSize = selectedItemManager:GetAbsoluteSizeFromItemSize(self.Size, self.Rotation)
			local ghostSize = UDim2.fromOffset(ghostAbsSize.X, ghostAbsSize.Y)

			if self._tweens.GhostSize then
				self._tweens.GhostSize:Cancel()
				self._tweens.GhostSize = nil
			end

			if useSizeTween then
				self._tweens.GhostSize = TweenService:Create(self.GhostElement, TweenInfo.new(0.25, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), { Size = ghostSize })
				self._tweens.GhostSize:Play()
			else
				self.GhostElement.Size = ghostSize
			end
		end

		local innerImage = self.ItemElement:FindFirstChild("Image", true)
		if innerImage and innerImage:IsA("ImageLabel") then
			if self._tweens.Rotation then
				self._tweens.Rotation:Cancel()
				self._tweens.Rotation = nil
			end

			local innerSize
			if currentRot % 2 == 1 then
				local targetX = absoluteElementSize.X
				local targetY = absoluteElementSize.Y
				if targetX > 0 and targetY > 0 then
					innerSize = UDim2.fromScale(targetY / targetX, targetX / targetY)
				else
					innerSize = UDim2.fromScale(1, 1)
				end
			else
				innerSize = UDim2.fromScale(1, 1)
			end

			innerImage.Rotation = currentRot * 90

			if useSizeTween then
				self._tweens.Rotation = TweenService:Create(innerImage, TweenInfo.new(0.25, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), { Size = innerSize })
				self._tweens.Rotation:Play()
			else
				innerImage.Size = innerSize
			end
		end
	end
end

--[=[
    Rotates the Item, has to be dragged to be rotatable.

    @within Item
]=]
function Item:Rotate(quartersOf360: number)
	assert(self.IsDragging, "Must be dragging to rotate an item!")

	self.PotentialRotation += quartersOf360
	if self.PotentialRotation > 3 then
		self.PotentialRotation -= 4
	elseif self.PotentialRotation < 0 then
		self.PotentialRotation += 4
	end

	-- Update highlight size for new rotation
	if self._highlight then
		if self.PotentialRotation % 2 == 1 then
			self._highlight.Size = Vector2.new(self.Size.Y, self.Size.X)
		else
			self._highlight.Size = self.Size
		end
	end

	local currentItemManager = self.HoveringItemManager or self.ItemManager
	local absoluteSize
	if currentItemManager then
		absoluteSize = currentItemManager:GetAbsoluteSizeFromItemSize(self.Size, self.PotentialRotation)
	else
		if self.PotentialRotation % 2 == 1 then
			absoluteSize = Vector2.new(self.ItemElement.Size.Y.Offset, self.ItemElement.Size.X.Offset)
		else
			absoluteSize = Vector2.new(self.ItemElement.Size.X.Offset, self.ItemElement.Size.Y.Offset)
		end
	end

	local elementSize = UDim2.fromOffset(absoluteSize.X, absoluteSize.Y)

	-- Cancel any in-flight size tweens so they don't overwrite our instant snap
	if self._tweens.Size then
		self._tweens.Size:Cancel()
		self._tweens.Size = nil
	end
	if self._tweens.GhostSize then
		self._tweens.GhostSize:Cancel()
		self._tweens.GhostSize = nil
	end

	-- Instantly snap the real, invisible ItemElement so all hitbox logic calculates correctly
	self.ItemElement.Size = elementSize

	-- Instantly snap the real image logic too
	local realImage = self.ItemElement:FindFirstChild("Image", true)
	local innerSize
	if self.PotentialRotation % 2 == 1 then
		local targetX = absoluteSize.X
		local targetY = absoluteSize.Y
		if targetX > 0 and targetY > 0 then
			innerSize = UDim2.fromScale(targetY / targetX, targetX / targetY)
		else
			innerSize = UDim2.fromScale(1, 1)
		end
	else
		innerSize = UDim2.fromScale(1, 1)
	end

	if realImage and realImage:IsA("ImageLabel") then
		realImage.Size = innerSize
		realImage.Rotation = self.PotentialRotation * 90
	end

	-- Update _ghostAccumulatedRot regardless of input source
	self._ghostAccumulatedRot = (self._ghostAccumulatedRot or 0) + (quartersOf360 * 90)

	-- Tween the ghost frame's Rotation for keyboard/gamepad input.
	-- During touch gestures the handler owns ghost rotation directly, so skip the tween.
	if self.GhostElement and not self._touchGestureActive then
		if self._tweens.GhostRotation then
			self._tweens.GhostRotation:Cancel()
			self._tweens.GhostRotation = nil
		end

		self._tweens.GhostRotation = TweenService:Create(self.GhostElement, TweenInfo.new(0.2, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out), {
			Rotation = self._ghostAccumulatedRot
		})
		self._tweens.GhostRotation:Play()
	end

	-- Update positions and collision from the new size
	self:_updateDraggingPosition(self._lastDragScreenPosition)
end

--[=[
    Moves an item to a new ItemManager. This should only be used for transferring Items between ItemManagers that aren't linked using TranferLinks.

    @within Item
]=]
function Item:SetItemManager(itemManager: Types.ItemManagerObject)
	if self.ItemManager ~= nil then
		self.ItemManager:RemoveItem(self)
	end

	repeat
		task.wait()
	until self.ItemManager == nil

	if itemManager.Items then
		itemManager:AddItem(self, nil, true)
	else
		itemManager:ChangeItem(self, true)
	end
end

--[=[
    Destroy the Item object.

    @within Item
]=]
function Item:Destroy()
	self._trove:Destroy()
end

return Item