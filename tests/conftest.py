import os
import sys

import pytest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(__file__))


@pytest.fixture(scope="session")
def backend():
    from aerosim.backend.zig import ZigBackend
    return ZigBackend()


@pytest.fixture(scope="session")
def manager(backend):
    from aerosim.manager import SimulationManager
    return SimulationManager(backend)
