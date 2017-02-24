FROM ubuntu

RUN apt-get update 
RUN apt-get install -y --no-install-recommends \
      apt-transport-https \
      ca-certificates \
      curl \
      python-software-properties \
      mosquitto-clients

RUN curl -fsSL https://apt.dockerproject.org/gpg | sudo apt-key add -
RUN add-apt-repository "deb https://apt.dockerproject.org/repo ubuntu-xenial main"
RUN apt-get update
RUN apt-get install -y docker-engine

COPY test.sh /test.sh
RUN chmod a+x /test.sh

CMD ["/test.sh"]