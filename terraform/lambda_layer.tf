# Stage 3 chunk E.1 — psycopg Lambda layer.
#
# Layer build is a three-step pipeline:
#   1. null_resource.build_psycopg_layer:
#        Runs `pip install --platform manylinux2014_aarch64 ...` to fetch
#        a precompiled arm64 Linux wheel from PyPI and lay it out under
#        lambda/layers/psycopg/build/python/. Fires only when
#        requirements.txt changes (hash trigger).
#   2. data "archive_file" "psycopg_layer":
#        Zips the build dir. depends_on the null_resource so it runs after.
#   3. aws_lambda_layer_version.psycopg:
#        Uploads the ZIP as a versioned layer in AWS. Lambda function
#        attaches via layers = [arn] (in lambda.tf).
#
# Why pip --platform instead of Docker: PyPI hosts pre-built
# manylinux2014_aarch64 wheels for psycopg-binary, so we can fetch the
# right binary without spinning up a container. Faster, no Docker
# dependency on the build machine.

resource "null_resource" "build_psycopg_layer" {
  # Fire whenever the layer's requirements.txt content changes. If the
  # build directory gets corrupted manually, run:
  #   terraform taint null_resource.build_psycopg_layer
  triggers = {
    requirements_hash = filemd5("${path.module}/../lambda/layers/psycopg/requirements.txt")
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/.."
    command     = <<-EOT
      set -e
      rm -rf lambda/layers/psycopg/build
      mkdir -p lambda/layers/psycopg/build/python
      python3 -m pip install \
        --platform manylinux2014_aarch64 \
        --target lambda/layers/psycopg/build/python \
        --implementation cp --python-version 3.12 \
        --only-binary=:all: --upgrade \
        -r lambda/layers/psycopg/requirements.txt
    EOT
  }
}

# Zip the build directory. The archive's source layout matters: AWS
# Lambda expects layer contents to be reachable at /opt/python/<package>,
# so the ZIP must have `python/...` at its root. archive_file with
# source_dir = build (which contains a python/ subdir) produces exactly
# that.
data "archive_file" "psycopg_layer" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/layers/psycopg/build"
  output_path = "${path.module}/build/psycopg-layer.zip"

  depends_on = [null_resource.build_psycopg_layer]
}

resource "aws_lambda_layer_version" "psycopg" {
  layer_name  = "${var.function_name}-psycopg"
  description = "Psycopg 3 Postgres driver, manylinux2014_aarch64 binary build."

  filename         = data.archive_file.psycopg_layer.output_path
  source_code_hash = data.archive_file.psycopg_layer.output_base64sha256

  compatible_runtimes      = ["python3.12"]
  compatible_architectures = ["arm64"]
}
