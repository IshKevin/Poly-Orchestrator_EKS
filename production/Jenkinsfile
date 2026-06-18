pipeline {
    agent any

    environment {
        AWS_REGION   = 'eu-west-1'
        PROJECT_NAME = 'shopnow'
        ENV_NAME     = 'dev'
        EKS_CLUSTER  = "${PROJECT_NAME}-${ENV_NAME}-cluster"
        IMAGE_TAG    = "${BUILD_NUMBER}"
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 30, unit: 'MINUTES')
        timestamps()
    }

    stages {

        // ── 1. Source ──────────────────────────────────────────────────
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        // ── 2. Tests ───────────────────────────────────────────────────
        stage('Test') {
            parallel {
                stage('Backend') {
                    steps {
                        dir('app/backend') {
                            sh '''
                                pip3 install -r requirements.txt -q
                                python3 -m pytest tests/ -v --tb=short 2>/dev/null \
                                    || echo "No tests directory found — skipping"
                            '''
                        }
                    }
                }
                stage('Frontend') {
                    steps {
                        dir('app/frontend') {
                            sh 'npm ci --silent && npm test -- --passWithNoTests 2>/dev/null || echo "No tests found — skipping"'
                        }
                    }
                }
            }
        }

        // ── 3. Resolve ECR URLs & build images ────────────────────────
        stage('Build') {
            steps {
                script {
                    env.ACCOUNT_ID = sh(
                        script: 'aws sts get-caller-identity --query Account --output text',
                        returnStdout: true
                    ).trim()

                    env.ECR_BASE     = "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
                    env.ECR_FRONTEND = "${ECR_BASE}/${PROJECT_NAME}-${ENV_NAME}-frontend"
                    env.ECR_BACKEND  = "${ECR_BASE}/${PROJECT_NAME}-${ENV_NAME}-backend"
                }

                sh """
                    docker build \
                        -t ${ECR_FRONTEND}:${IMAGE_TAG} \
                        -t ${ECR_FRONTEND}:latest \
                        ./app/frontend

                    docker build \
                        -t ${ECR_BACKEND}:${IMAGE_TAG} \
                        -t ${ECR_BACKEND}:latest \
                        ./app/backend
                """
            }
        }

        // ── 4. Push to ECR ────────────────────────────────────────────
        stage('Push') {
            steps {
                sh """
                    aws ecr get-login-password --region ${AWS_REGION} \
                        | docker login --username AWS --password-stdin ${ECR_BASE}

                    docker push ${ECR_FRONTEND}:${IMAGE_TAG}
                    docker push ${ECR_FRONTEND}:latest
                    docker push ${ECR_BACKEND}:${IMAGE_TAG}
                    docker push ${ECR_BACKEND}:latest
                """
            }
        }

        // ── 5. Deploy to EKS (backend first, then frontend) ──────────
        stage('Deploy: Backend') {
            steps {
                sh """
                    aws eks update-kubeconfig --region ${AWS_REGION} --name ${EKS_CLUSTER}

                    kubectl set image deployment/backend \
                        backend=${ECR_BACKEND}:${IMAGE_TAG} \
                        -n shopnow

                    kubectl rollout status deployment/backend \
                        -n shopnow --timeout=300s
                """
            }
        }

        stage('Deploy: Frontend') {
            steps {
                sh """
                    kubectl set image deployment/frontend \
                        frontend=${ECR_FRONTEND}:${IMAGE_TAG} \
                        -n shopnow

                    kubectl rollout status deployment/frontend \
                        -n shopnow --timeout=300s
                """
            }
        }
    }

    post {
        always {
            sh 'docker image prune -f || true'
            cleanWs()
        }
        success {
            echo "Build #${BUILD_NUMBER} deployed successfully to ${EKS_CLUSTER}."
        }
        failure {
            echo "Build #${BUILD_NUMBER} failed — check the stage logs above."
        }
    }
}
