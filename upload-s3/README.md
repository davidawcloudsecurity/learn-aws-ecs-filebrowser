### How to install Filebrowser
https://filebrowser.org/installation
```
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
```
Run this with specific path
```
filebrowser -r /path/to/your/files
```
### How to custom port
```
/filebrowser --port 80 --address 0.0.0.0
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
