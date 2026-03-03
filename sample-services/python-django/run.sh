#!/bin/bash

echo "Running migration"
python3 manage.py makemigrations
python3 manage.py migrate

echo "Starting web server"
python3 manage.py runserver 8080