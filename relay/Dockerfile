FROM ubuntu

# Update and install basic utilities
RUN apt-get update -y
RUN apt-get install -y software-properties-common python3-pip wget iputils-ping curl libffi-dev libssl-dev pkg-config logrotate sudo
RUN pip3 install --upgrade pip
RUN pip3 install paho-mqtt 

ADD ./start.sh /
RUN chmod a+x /start.sh

ADD ./mqtt-message-relay.py /
RUN chmod a+x /mqtt-message-relay.py

ENTRYPOINT /start.sh local