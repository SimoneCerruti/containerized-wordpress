#!/bin/bash

set -e

# 1. Supervisord
supervisorctl status > /dev/null 2>&1 || exit 1

# 2. PHP-FPM
SCRIPT_NAME=/ping \
SCRIPT_FILENAME=/ping \
REQUEST_METHOD=GET \
cgi-fcgi -bind -connect 127.0.0.1:9000 > /dev/null 2>&1 || exit 1

# 3. Nginx
curl -sf http://127.0.0.1/robots.txt > /dev/null 2>&1 || \
curl -sf http://127.0.0.1/ > /dev/null 2>&1 || exit 1

exit 0