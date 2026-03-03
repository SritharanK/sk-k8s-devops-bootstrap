# -----------------------------------------------------------------------------
# Project: GitOps Kubernetes Platform Bootstrap
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------
from django.contrib import admin

from .models import Profile

admin.site.register(Profile)

# admin.site.register(Position)

# admin.site.register(DeveloperStory)

