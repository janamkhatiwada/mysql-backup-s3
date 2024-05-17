#!/bin/bash

# Set the has_failed variable to false. This will change if any of the subsequent database backups/uploads fail.
has_failed=false

# Loop through all the defined databases, separating by a comma
for CURRENT_DATABASE in ${TARGET_DATABASE_NAMES//,/ }
do

    # Perform the database backup. Put the output to a variable. If successful upload the backup to S3, if unsuccessful print an entry to the console and the log, and set has_failed to true.
    if sqloutput=$(mysqldump -u $TARGET_DATABASE_USER -h $TARGET_DATABASE_HOST -p$TARGET_DATABASE_PASSWORD -P $TARGET_DATABASE_PORT $CURRENT_DATABASE --single-transaction --skip-lock-tables  | gzip 2>&1 > /tmp/$CURRENT_DATABASE-$(date +'%d-%m-%Y').sql.gz)
    then
        
        echo -e "Database backup successfully completed for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S')."

        # Perform the upload to S3. Put the output to a variable. If successful, print an entry to the console and the log. If unsuccessful, set has_failed to true and print an entry to the console and the log
        if awsoutput=$(aws s3 cp /tmp/$CURRENT_DATABASE-$(date +'%d-%m-%Y').sql.gz s3://$AWS_BUCKET_NAME/$AWS_BUCKET_BACKUP_PATH/$CURRENT_DATABASE-$(date +'%d-%m-%Y').sql.gz 2>&1)
        then
            echo -e "Database backup successfully uploaded for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S')."
        else
            echo -e "Database backup failed to upload for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S'). Error: $awsoutput" | tee -a /tmp/kubernetes-s3-mysql-backup.log
            has_failed=true
        fi

    else
        echo -e "Database backup FAILED for $CURRENT_DATABASE at $(date +'%d-%m-%Y %H:%M:%S'). Error: $sqloutput" | tee -a /tmp/kubernetes-s3-mysql-backup.log
        has_failed=true
    fi

done

# Check if any of the backups have failed. If so, exit with a status of 1. Otherwise exit cleanly with a status of 0.
if [ "$has_failed" = true ]
then

    # If Slack alerts are enabled, send a notification alongside a log of what failed
    if [ "$SLACK_ENABLED" = true ]
    then
        # Put the contents of the database backup logs into a variable
        logcontents=$(cat /tmp/kubernetes-s3-mysql-backup.log)

        # Send Slack alert
        /slack-alert.sh "One or more backups of database *${TARGET_DATABASE_NAMES//,/ }* on host *$TARGET_DATABASE_HOST* failed. The error details are included below:" "$logcontents"
    fi

    echo -e "kubernetes-s3-mysql-backup encountered 1 or more errors. Exiting with status code 1."
    exit 1

else

    # Initialize deleted file count
    deleted_count=0

    # List files in S3 bucket and save the output to a temporary file
    aws s3 ls s3://$AWS_BUCKET_NAME/$AWS_BUCKET_BACKUP_PATH/ > /tmp/s3_file_list.txt

    # Loop through files in S3 bucket and delete files older than specified threshold
    while IFS= read -r line;
    do
        createDate=$(echo "$line" | awk '{print $1" "$2}')
        createDate=$(date -d"$createDate" +%s)
        olderThan=$(date -d "$DELETE_OLDER_THAN ago" +%s)
        if [ "$createDate" -lt "$olderThan" ]; then
            fileName=$(echo "$line" | awk '{print $4}')
            if [ -n "$fileName" ]; then
                # Delete file
                if aws s3 rm "s3://$AWS_BUCKET_NAME/$AWS_BUCKET_BACKUP_PATH/$fileName"; then
                    deleted_count=$((deleted_count + 1)) # Increment deleted file count
                else
                    echo "Failed to delete file: $fileName"
                fi
            fi
        fi
    done < /tmp/s3_file_list.txt

    # Check if any files were deleted
    if [ "$deleted_count" -gt 0 ]; then
        echo "$deleted_count files deleted from bucket $AWS_BUCKET_NAME/$AWS_BUCKET_BACKUP_PATH/"
        delete=true
        echo "$delete"
    else
        echo "No files older than $DELETE_OLDER_THAN in bucket $AWS_BUCKET_NAME/$AWS_BUCKET_BACKUP_PATH/"
        delete=false
        echo "$delete"
    fi

    # If Slack alerts are enabled, send a notification indicating the status of database backups
    if [ "$SLACK_ENABLED" = true ]; then
        if [ "$delete" = true ]; then
            # Send Slack alert for successful backups with deletion
            /slack-alert.sh "All database backups successfully completed for databases *${TARGET_DATABASE_NAMES//,/ }* on host *$TARGET_DATABASE_HOST*. Backups older than $DELETE_OLDER_THAN days were deleted."
        else
            # Send Slack alert for successful backups without deletion
            /slack-alert.sh "All database backups successfully completed for databases *${TARGET_DATABASE_NAMES//,/ }* on host *$TARGET_DATABASE_HOST*."
        fi
    fi

    # Clear the files in /tmp/ folder regardless of deletion status
    rm -rf /tmp/*

    # Exit with status code 0
    exit 0
fi
