FROM ubuntu

RUN apt-get update 
RUN apt-get install -y --no-install-recommends \
      mosquitto-clients \
      curl \
      apt-transport-https \
      ca-certificates \
      curl \
      python-software-properties

RUN apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys
RUN add-apt-repository "deb https://apt.dockerproject.org/repo ubuntu-xenial main"
RUN apt-get update
RUN apt-get install -y docker-engine

COPY test.sh /test.sh
RUN chmod a+x /test.sh

CMD ["/test.sh"]