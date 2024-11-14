resource "aws_glue_crawler" "s3_crawler" {
  database_name = var.glue_table_name
  role          = var.glue_role_arn
  name          = var.function_name

  s3_target {
    path = "s3://${local.bucket_name}/${local.prefix}/"
  }

  schema_change_policy {
    update_behavior = "LOG"
    delete_behavior = "LOG"
  }
  recrawl_policy {
    recrawl_behavior = "CRAWL_EVERYTHING"
  }
}
