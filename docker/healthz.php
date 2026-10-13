<?php
// Lightweight health endpoint used by the Docker HEALTHCHECK and by the
// Kubernetes liveness/readiness probes.
// It intentionally does NOT load the ProjeQtOr framework so that it stays
// fast and keeps working even when the application is misconfigured.
header('Content-Type: text/plain; charset=utf-8');
http_response_code(200);
echo 'OK';
