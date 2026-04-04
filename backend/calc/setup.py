import sys
from setuptools import setup
from pybind11.setup_helpers import Pybind11Extension, build_ext

extra_compile_args = []
if sys.platform == "win32":
    extra_compile_args = ["/O2", "/std:c++17"]
else:
    extra_compile_args = ["-O3", "-std=c++17"]

setup(
    name="filter_core",
    ext_modules=[
        Pybind11Extension(
            "filter_core",
            ["filter_core.cpp"],
            extra_compile_args=extra_compile_args,
        )
    ],
    cmdclass={"build_ext": build_ext},
)
