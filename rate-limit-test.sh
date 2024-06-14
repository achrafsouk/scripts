#!/bin/bash 
# this bash scripts tests the delay of blocking an IP that exceeds a request rate limit threshold
rl_limit=250 #Rate limit that needs to be tested
url=$(echo test.achrafsouk.com) #URL where rate limit is applied

# send the a number of request matching the limit
counter=0
until [ $counter = $rl_limit ]
do
result=$(curl -I --silent $url | grep HTTP)
echo $(date +%s) : request number $(($counter+1)) : $result
((counter=counter+1))
done

t_start=$(date +%s)

# send the a number of request beyong the limit until blocked
counter=0
result=''
until [[ $(echo $result | grep '403 Forbidden') == *"403"* ]]
do
result=$(curl -I --silent $url | grep HTTP)
echo $(date +%s) : request number $(($counter+1)) : $result
((counter=counter+1))
done

t_end=$(date +%s)
elapsed_time=$(($t_end-$t_start))
echo total time to block : $elapsed_time seconds
