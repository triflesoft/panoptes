#!/usr/bin/env python

from typing import Union
from fastapi import FastAPI

app = FastAPI()

@app.get("/radius/authorize")
async def radius_authorize():
    return {}

@app.get("/radius/accounting")
async def radius_accounting():
    return {}
