# lms-lmq-beta

It is very likely that this will take some troubleshooting to get working on your system. 

Currently only tested with Heos and haven't tested with all services.

Still missing many fuctions.

1. Setup you Heos player using Heos App

2. Download and import https://github.com/benumc/lms-lmq-beta/raw/master/lmslmq_heos-player.xml

3. Add lmslmq_heos-player to Savant project file

4. Put the name of the heos player that you want to control into the hostname field.

5. Make audio and data connections

6. Put the IP Address of the Savant Host on the ethernet wire and modify the state variables with heos account info and desired top menu items.

7. Generate Services and create a trigger called lmslmq

8. Make the trigger run every time global.CurrentMinute Changes

9. Create a new general service request workflow.

10. Add RunScript to your workflow and set it to /bin/zsh

11. Paste the following in to the action.

```
if ps ax | grep -v grep | grep LMSLMQ 
then
else
if [ ! -d lms-lmq-beta ]
then
rm -r lms-lmq-beta-master
curl -LOk https://github.com/benumc/lms-lmq-beta/archive/master.zip
unzip master.zip
rm master.zip
fi
nohup ruby lms-lmq-beta-master/LMSLMQ.rb >/dev/null 2>&1 &
fi
```
