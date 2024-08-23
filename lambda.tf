data "archive_file" "failover_lambda" {
  output_path = "${path.module}/dist/failover.zip"
  source_file = "${path.module}/src/main.py"
  type        = "zip"
}

module "lambda" {
  source  = "moritzzimmer/lambda/aws"
  version = "7.5.0"

  architectures = ["arm64"]
  description            = "Crawl security services to CUDOS athena table."
  ephemeral_storage_size = 512
  filename               = data.archive_file.failover_lambda.output_path
  function_name          = var.function_name
  handler                = "main.lambda_handler"
  memory_size            = 1024
  runtime                = "python3.12"
  publish                = false
  snap_start             = false
  source_code_hash       = data.archive_file.failover_lambda.output_base64sha256
  timeout = 600

  // logs and metrics
  cloudwatch_logs_enabled            = true
  cloudwatch_logs_retention_in_days  = 7
  cloudwatch_lambda_insights_enabled = true
  layers = ["arn:aws:lambda:${data.aws_region.current.id}:580247275435:layer:LambdaInsightsExtension-Arm64:5"]

  environment = {
    variables = {
      BUCKET_NAME  = local.bucket_name
      PREFIX       = local.prefix
      ROLE_NAME    = var.role_name
      CRAWLER_NAME = aws_glue_crawler.s3_crawler.name
      REGIONS      = "eu-west-1,eu-central-1,eu-north-1,us-east-1"
    }
  }

  tags = {
    key = "value"
  }
}

resource "aws_iam_role_policy_attachment" "this" {
  policy_arn = aws_iam_policy.this.arn
  role       = module.lambda.role_name
}

resource "aws_iam_policy" "this" {
  name   = "${var.function_name}-${data.aws_region.current.name}"
  policy = data.aws_iam_policy_document.this.json
}

data "aws_iam_policy_document" "this" {
  statement {
    sid = "Organizations"
    actions = ["organizations:DescribeOrganization", "organizations:List*"]
    resources = ["*"]
  }

  statement {
    sid = "StartCrawlerForResults"
    actions = ["glue:StartCrawler",]

    resources = [aws_glue_crawler.s3_crawler.arn]
  }

  statement {
    sid = "WriteResults"
    actions = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${local.bucket_name}/*", "arn:aws:s3:::${local.bucket_name}"]
  }

  statement {
    sid = "AssumeRole"
    actions = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::*:role/${var.role_name}"]
  }
}


resource "aws_cloudwatch_event_rule" "cron" {
  name                = "cron"
  description         = "Run the lambda every day"
  schedule_expression = "rate(1 day)"
}

resource "aws_cloudwatch_event_target" "cron" {
  rule = aws_cloudwatch_event_rule.cron.name
  arn  = module.lambda.arn
}

resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cron.arn
}
