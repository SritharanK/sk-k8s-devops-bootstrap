# -----------------------------------------------------------------------------
# Project: GitOps Kubernetes Platform Bootstrap
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------
from django.contrib import admin

from .models import Notification,PrivRepNotification

admin.site.register(Notification)

admin.site.register(PrivRepNotification)
