terraform {
  required_providers {
      aws = {
      source  = "hashicorp/aws"
      version = "~>3.0"
    }
  }
}

provider "aws" {
    region = "us-east-1"
    access_key = "${var.aws_access_key}"
    secret_key = "${var.aws_secret_key}"
}

resource "aws_default_vpc" "default_vpc" {

}

resource "aws_default_subnet" "aws_default_subnet_a" {
    availability_zone = "us-east-1a"
}

resource "aws_default_subnet" "aws_default_subnet_b" {
    availability_zone = "us-east-1b"
}

resource "aws_default_subnet" "aws_default_subnet_c" {
    availability_zone = "us-east-1c"
}

resource "aws_ecr_repository" "aws-repo" {
    name = "${var.repo_name}-repo"
}

module "ecr_docker_build" {
    source = "github.com/byu-oit/terraform-aws-ecr-image?ref=v1.0.1"
    dockerfile_dir = "."
    ecr_repository_url = "${aws_ecr_repository.aws-repo.repository_url}"
}


resource "aws_ecs_cluster" "aws-cluster" {
    name = "${var.cluster_name}-cluster"
}

resource "aws_iam_role" "ecsTaskExecutionRole" {
    name = "${var.app_name}-execution-task-role"
    assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
}

data "aws_iam_policy_document" "assume_role_policy" {
    statement {
        actions = ["sts:AssumeRole"]

        principals {
            type = "Service"
            identifiers = ["ecs-tasks.amazonaws.com"]
        }
    }
    depends_on = [module.ecr_docker_build]
}

resource "aws_iam_policy_attachment" "ecsTaskExecutionRole_policy" {
    name = "${var.app_name}-aws_iam_policy_attachment"
    roles = ["${aws_iam_role.ecsTaskExecutionRole.name}"]
    policy_arn = "arn:aws:iam:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "aws-task" {
    family = "${var.app_name}-task"
    container_definitions = <<DEFINITION
    [
        {
            "name": "${var.app_name}-task",
            "image": "${aws_ecr_repository.aws-repo.repository_url}:latest",
            "essential": true,
            "portMappings": [
                {
                    "containerPort": 8080,
                    "hostPort": 8080
                }
            ],
            "cpu": 256,
            "memory": 512,
            "networkMode": "awsvpc"
        }
    ]
        
    DEFINITION
    requires_compatibilities = ["FARGATE"]
    network_mode             = "awsvpc"
    memory                   = "512"
    cpu                      = "256"
}

resource "aws_alb" "application_load_balancer" {
    name = "${var.app_name}-load_balancer"
    load_balancer_type = "application"
    subnets = [
        "${aws_default_subnet.aws_default_subnet_a.id}",
        "${aws_default_subnet.aws_default_subnet_b.id}",
        "${aws_default_subnet.aws_default_subnet_c.id}"
    ]
    security_groups = ["${aws_security_group.load_balancer_security_group.id}"]

}

resource "aws_security_group" "load_balancer_security_group" {
    
    ingress {
        from_port = 80
        to_port = 80
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
        ipv6_cidr_blocks = ["::/0"]
    }
}

resource "aws_lb_target_group" "target_group" {
    name = "${var.app_name}-target_group"
    port = 80
    protocol = "HTTP"
    target_type = "ip"
    vpc_id = "${aws_default_vpc.default_vpc.id}"
    depends_on = [aws_alb.application_load_balancer]

}

resource "aws_lb_listener" "listener" {
    load_balancer_arn = "${aws_alb.application_load_balancer.arn}"
    port = 80
    protocol = "HTTP"
    default_action {
        type = "forward"
        target_group_arn = "${aws_lb_target_group.target_group.arn}"
    }
}

resource "aws_ecs_service" "aws-ecs-service" {
  name                 = "${var.app_name}-ecs-service"
  cluster              = "${aws_ecs_cluster.aws-cluster.id}"
  task_definition      = "${aws_ecs_task_definition.aws-task.arn}"
  launch_type          = "FARGATE"
  scheduling_strategy  = "REPLICA"
  desired_count        = 2
  force_new_deployment = true

  network_configuration {
    subnets = [
        "${aws_default_subnet.aws_default_subnet_a.id}",
        "${aws_default_subnet.aws_default_subnet_b.id}",
        "${aws_default_subnet.aws_default_subnet_c.id}"
    ]
    assign_public_ip = true
    security_groups = [
      "${aws_security_group.service_security_group.id}",
      "${aws_security_group.load_balancer_security_group.id}"
    ]
  }

  load_balancer {
    target_group_arn = "${aws_lb_target_group.target_group.arn}"
    container_name   = "${var.app_name}-container"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.listener]
}

resource "aws_security_group" "service_security_group" {
    
    ingress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        security_groups = ["${aws_security_group.load_balancer_security_group.id}"]
    }

    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
        ipv6_cidr_blocks = ["::/0"]
    }
}

output "lb_address" {
    value = aws_alb.application_load_balancer.dns_name
}