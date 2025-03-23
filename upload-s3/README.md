### How to install Filebrowser
Simple Bucket policy
```
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::YOUR_AWS_ACCOUNT_ID:role/YOUR_ROLE_NAME"
            },
            "Action": "s3:*",
            "Resource": [
                "arn:aws:s3:::your-bucket-name",
                "arn:aws:s3:::your-bucket-name/*"
            ]
        }
    ]
}
```
User data
```
#!/bin/bash
apt update -y
apt install s3fs
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
s3fs
filebrowser version
cd /home/ssm-user
```
https://filebrowser.org/installation
```
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
```
Run this with specific path
```
filebrowser --port 80 --address 0.0.0.0 -r /path/to/your/files
```
### How to install s3fuse to be used as mount point
https://github.com/s3fs-fuse/s3fs-fuse
### How to use s3fuse
Use instance profile
```
s3fs my-filebrowser-bucket-caipirjj /srv/s3bucket -o iam_role=auto -o allow_other -o umask=0022 -o dbglevel=info'
```
Use access key and secret
```
echo ACCESS_KEY_ID:SECRET_ACCESS_KEY > ${HOME}/.passwd-s3fs
chmod 600 ${HOME}/.passwd-s3fs
```
```
s3fs mybucket /path/to/mountpoint -o passwd_file=${HOME}/.passwd-s3fs
```
