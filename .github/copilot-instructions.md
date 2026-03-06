# Copilot Instructions for GridPack

## Project Overview

GridPack is a Roblox Lua (Luau) library for creating grid/tetris-style inventories. It provides an API for managing items within grid-based or single-slot inventory containers, along with drag-and-drop interactions, item rotation, collision detection, and transfer between inventory managers.

## Repository Structure

- `src/` — Main library source code
  - `init.lua` — Entry point; exports `createItem`, `createGrid`, `createSingleSlot`, `createTransferLink`
  - `Item.lua` — Item class: draggable GUI element with position, size, rotation, and middleware support
  - `ItemManager/` — Container classes: `Grid.lua` (multi-slot grid), `SingleSlot.lua` (single-item slot)
  - `TransferLink.lua` — Links multiple ItemManagers so items can be dragged between them
  - `Highlight.lua` — Visual highlight overlay used during drag-and-drop
  - `Types.lua` — Luau type definitions for all public-facing objects and properties
- `test/` — Test place scripts (`client/`, `server/`)
- `docs/` — Documentation source files
- `wally.toml` — Package metadata and dependencies (Wally package manager)
- `selene.toml` — Selene linter configuration (`std = "roblox"`)
- `moonwave.toml` — Moonwave documentation generator configuration

## Language and Runtime

- All source code is written in **Luau** (Roblox's typed superset of Lua 5.1)
- The library runs in the **Roblox** game engine; all Roblox globals (`game`, `Instance`, `UDim2`, `Vector2`, `Color3`, `Enum`, etc.) are available
- Use `std = "roblox"` Selene linter standard

## Coding Conventions

### Object-Oriented Pattern
All classes use the standard Roblox/Luau OOP pattern:
```lua
local MyClass = {}
MyClass.__index = MyClass

function MyClass.new(properties): Types.MyClassObject
    local self = setmetatable({}, MyClass)
    -- ...
    return self
end

function MyClass:Destroy()
    self._trove:Destroy()
end

return MyClass
```

### Naming Conventions
- **PascalCase** for class names, public properties, and methods (e.g., `Item`, `ItemManager`, `AddItem`)
- **camelCase** for local variables (e.g., `gridPos`, `itemManager`)
- **`_camelCase`** prefix for private fields and methods (e.g., `self._trove`, `self:_updateDraggingPosition()`)
- **Section headers** use `--//` comments (e.g., `--// Services`, `--// Packages`, `--// Types`)

### Type Annotations
Always use Luau type annotations for function parameters and return values. All exported types live in `src/Types.lua`:
```lua
function Item.new(properties: Types.ItemProperties): Types.ItemObject
```

### Lifecycle Management
- Use **Trove** (`sleitnick/trove`) for cleanup — add all connections, instances, and objects to `self._trove` so they are cleaned up on `Destroy()`
- Sub-troves (`self._itemManagerTrove`, `self._draggingTrove`) are created for scoped cleanup

### Signals
- Use **Signal** (`sleitnick/signal`) for custom events
- Follow the pattern: `self.SomethingChanged = Signal.new()` and `self.SomethingChanged:Fire(value)`

### Documentation Comments
Public API uses Moonwave-style doc comments:
```lua
--[=[
    Description of the function.

    @param paramName ParamType -- description
    @return ReturnType

    @within ClassName
]=]
```
Private methods use `@private` tag.

## Dependencies

Managed via [Wally](https://wally.run). Current dependencies:
- `sleitnick/signal@2.0.1` — Signal/event library
- `sleitnick/trove@1.1.0` — Cleanup/lifecycle utility

## Linting

[Selene](https://kampfkarren.github.io/selene/) is used for linting with `std = "roblox"`. Run `selene src/` to lint the source.

## Documentation

[Moonwave](https://eryn.io/moonwave/) generates the API docs website. Configuration is in `moonwave.toml`.
