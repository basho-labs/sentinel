FROM ubuntu

RUN apt-get update
RUN apt-get install -y \
      apt-transport-https \
      ca-certificates \
      curl \
      python-software-properties \
      mosquitto-clients \
      python-pip \
      sudo \
      software-properties-common \
      python-setuptools

RUN curl -fsSL https://apt.dockerproject.org/gpg | sudo apt-key add -
RUN add-apt-repository "deb https://apt.dockerproject.org/repo ubuntu-xenial main"
RUN apt-get update
RUN apt-get install -y docker-engine

RUN pip install --upgrade pip
RUN pip install pytest paho-mqtt pytest-timeout

COPY start.sh /start.sh
RUN chmod a+x /start.sh
COPY tester.py /tester.py
RUN chmod a+x /tester.py

ENTRYPOINT /start.sh