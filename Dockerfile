FROM ubuntu:latest

# RUN apt-get update && \
#     apt-get install -y gnupg2 && \
#     echo "deb http://dk.archive.ubuntu.com/ubuntu/ xenial main" >> /etc/apt/sources.list && \
#     echo "deb http://dk.archive.ubuntu.com/ubuntu/ xenial universe" >> /etc/apt/sources.list && \
#     apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 40976EAF437D05B5 && \
#     apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 3B4FE6ACC0B21F32 && \
#     apt-get update && \
#     apt-get install -y gcc && \
#     gcc --version

RUN apt-get update
RUN apt-get install -y gnupg2 
RUN echo "deb http://dk.archive.ubuntu.com/ubuntu/ xenial main" >> /etc/apt/sources.list
RUN echo "deb http://dk.archive.ubuntu.com/ubuntu/ xenial universe" >> /etc/apt/sources.list
RUN apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 40976EAF437D05B5
RUN apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 3B4FE6ACC0B21F32
RUN apt-get update
RUN apt-get install -y gcc-4.9