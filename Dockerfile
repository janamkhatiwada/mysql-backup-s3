# Set the base image
FROM alpine:3.6

RUN apk -v --update add \
        coreutils \
        bash \
        python3 \
        py3-pip \
        groff \
        less \
        mailcap \
        mysql-client \
        curl \
        gawk \
        && \
    rm /var/cache/apk/*

RUN pip3 install --upgrade pip && \
    pip3 install --upgrade awscli
RUN aws --version

# Set Default Environment Variables
ENV TARGET_DATABASE_PORT=3306
ENV SLACK_ENABLED=true
ENV SLACK_USERNAME=ghg-db-backup-bot

# Copy Slack Alert script and make executable
COPY resources/slack-alert.sh /
RUN chmod +x /slack-alert.sh

# Copy backup script and execute
COPY resources/perform-backup.sh /perform-backup.sh
RUN chmod +x /perform-backup.sh
CMD ["sh", "/perform-backup.sh"]