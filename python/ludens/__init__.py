"""ludens: Python bindings for ludens-engine (ROADMAP 17.21).

A ctypes layer over the frozen C-ABI (`embed/ludens.h`, ROADMAP 12.1); the
shared library and the Mojo runtime libraries it needs ship inside the
package, so an installed wheel does not need the repository or a Mojo
toolchain.

    import ludens
    with ludens.World() as w:
        w.add_box((0, -0.5, 0), (10, 0.5, 10), static=True)
        b = w.add_sphere((0, 2, 0), 0.25)
        w.step_ticks(60)
        print(b.state().pos)
"""

from ._capi import library_path
from .world import (
    BEGAN,
    ENDED,
    POST,
    PRE,
    STAY,
    ArgumentError,
    Body,
    BodyState,
    BufferTooSmallError,
    CallbackError,
    ContactEvent,
    FormatError,
    TransferError,
    HandleError,
    Hit,
    LudensError,
    NavMesh,
    StaleBodyError,
    StateError,
    ThreadError,
    World,
    abi_version,
)
from .cvar import CVar, CVarRegistry, bind_world
from .hot import HotSystem

__version__ = "0.1.0"
