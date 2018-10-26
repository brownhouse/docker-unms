# Multi-stage build - See https://docs.docker.com/engine/userguide/eng-image/multistage-build
FROM ubnt/unms:0.13.1-connection.2 as unms
FROM ubnt/unms-netflow:0.13.1-connection.2 as unms-netflow
FROM oznu/s6-node:8.12.0-amd64

# base deps redis, rabbitmq
RUN echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories \
  && apk add --no-cache vips redis rabbitmq-server \
  && apk del ${devDeps} \
  && deluser rabbitmq \
  && addgroup -S rabbitmq && adduser -S -h /var/lib/rabbitmq -G rabbitmq rabbitmq \
  && mkdir -p /var/lib/rabbitmq /etc/rabbitmq \
  && chown -R rabbitmq:rabbitmq /var/lib/rabbitmq /etc/rabbitmq \
  && chmod -R 777 /var/lib/rabbitmq /etc/rabbitmq \
  && ln -sf /var/lib/rabbitmq/.erlang.cookie /root/

# postgres 9.6.10 https://pkgs.alpinelinux.org/packages?name=postgresql&branch=v3.6
RUN apk add --no-cache --repository http://dl-cdn.alpinelinux.org/alpine/v3.6/main postgresql==9.6.10-r0 postgresql-client=9.6.10-r0 postgresql-contrib=9.6.10-r0 libpq=9.6.10-r0 

# start ubnt/unms dockerfile #
RUN mkdir -p /home/app/unms

WORKDIR /home/app/unms

# Copy UNMS app from offical image since the source code is not published at this time
COPY --from=unms /home/app/unms /home/app/unms

RUN devDeps="vips-dev fftw-dev make python g++" \
    && apk add --no-cache ${devDeps} su-exec gzip bash vim dumb-init openssl vips libcap \
    && rm -rf node_modules \
    && JOBS=$(nproc) npm install \
    && apk del ${devDeps} \
    && mkdir -p -m 777 "$HOME/unms/public/site-images" \
    && mkdir -p -m 777 "$HOME/unms/data/config-backups" \
    && mkdir -p -m 777 "$HOME/unms/data/unms-backups" \
    && mkdir -p -m 777 "$HOME/unms/data/import"

RUN setcap cap_net_raw=pe $(which node)

COPY --from=unms /usr/local/bin/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
# end ubnt/unms dockerfile #

# start unms-netflow dockerfile #
RUN mkdir -p /home/app/netflow

COPY --from=unms-netflow /home/app /home/app/netflow

RUN devDeps="vips-dev fftw-dev make python g++" \
  && apk add --no-cache ${devDeps} \
  && cd /home/app/netflow \
  && JOBS=$(nproc) npm install \
  && apk del ${devDeps}

# end unms-netflow dockerfile #

# ubnt/nginx docker file #
ENV NGINX_UID=1000 \
    NGINX_VERSION=nginx-1.12.2 \
    LUAJIT_VERSION=2.1.0-beta3

RUN set -x && devDeps="wget pcre-dev zlib-dev build-base libffi-dev python-dev build-base" \
    # && apk del libressl-dev curl-dev libssh2-dev \
    && apk add --no-cache --update ${devDeps} sudo dumb-init pcre libgcc gettext py-pip \
    && pip install certbot==0.21.0 \
    && mkdir -p /tmp/src && cd /tmp/src \
    && wget -q http://nginx.org/download/${NGINX_VERSION}.tar.gz -O nginx.tar.gz \
    && wget -q https://github.com/openresty/lua-nginx-module/archive/v0.10.11.tar.gz -O lua-nginx-module.tar.gz \
    && wget -q https://github.com/simpl/ngx_devel_kit/archive/v0.3.0.tar.gz -O ndk.tar.gz \
    && wget -q http://luajit.org/download/LuaJIT-${LUAJIT_VERSION}.tar.gz -O luajit.tar.gz \
    && tar -zxvf lua-nginx-module.tar.gz \
    && tar -zxvf ndk.tar.gz \
    && tar -zxvf luajit.tar.gz \
    && tar -zxvf nginx.tar.gz \
    && cd /tmp/src/LuaJIT-${LUAJIT_VERSION} && make amalg PREFIX='/usr' && make install PREFIX='/usr' \
    && export LUAJIT_LIB=/usr/lib/libluajit-5.1.so && export LUAJIT_INC=/usr/include/luajit-2.1 \
    && cd /tmp/src/${NGINX_VERSION} && ./configure \
        --with-cc-opt='-g -O2 -fPIE -fstack-protector-strong -Wformat -Werror=format-security -fPIC -Wdate-time -D_FORTIFY_SOURCE=2' \
        --with-ld-opt='-Wl,-Bsymbolic-functions -fPIE -pie -Wl,-z,relro -Wl,-z,now -fPIC' \
        --with-pcre-jit \
        --with-threads \
        --add-module=/tmp/src/lua-nginx-module-0.10.11 \
        --add-module=/tmp/src/ngx_devel_kit-0.3.0 \
        --with-http_ssl_module \
        --with-http_realip_module \
        --with-http_gzip_static_module \
        --with-http_secure_link_module \
        --without-mail_pop3_module \
        --without-mail_imap_module \
        --without-http_upstream_ip_hash_module \
        --without-http_memcached_module \
        --without-http_auth_basic_module \
        --without-http_userid_module \
        --without-http_fastcgi_module \
        --without-http_uwsgi_module \
        --without-http_scgi_module \
        --prefix=/var/lib/nginx \
        --sbin-path=/usr/sbin/nginx \
        --conf-path=/etc/nginx/nginx.conf \
        --http-log-path=/dev/stdout \
        --error-log-path=/dev/stderr \
        --lock-path=/tmp/nginx.lock \
        --pid-path=/tmp/nginx.pid \
        --http-client-body-temp-path=/tmp/body \
        --http-proxy-temp-path=/tmp/proxy \
    && make -j $(nproc) \
    && make install \
    && apk del ${devDeps} \
    && rm /usr/bin/luajit-${LUAJIT_VERSION} \
    && rm -rf /tmp/src \
    && rm -rf /var/cache/apk/* \
    && echo "unms ALL=(ALL) NOPASSWD: /usr/sbin/nginx -s *" >> /etc/sudoers \
    && echo "unms ALL=(ALL) NOPASSWD:SETENV: /copy-user-certs.sh reload" >> /etc/sudoers

ADD https://github.com/Ubiquiti-App/UNMS/archive/v0.13.1-connection.2.tar.gz /tmp/unms.tar.gz

RUN cd /tmp \
    && tar -xzf unms.tar.gz \
    && cd UNMS-*/src/nginx \
    && cp entrypoint.sh refresh-certificate.sh fill-template.sh openssl.cnf *.conf.template / \
    && mkdir -p /www/public \
    && cp -R public /www/ \
    && chmod +x /entrypoint.sh /fill-template.sh /refresh-certificate.sh
# end ubnt/nginx docker file #

ENV PATH=/home/app/unms/node_modules/.bin:$PATH \
  PGDATA=/config/postgres \
  POSTGRES_DB=unms \
  QUIET_MODE=0 \
  WS_PORT=443 \
  PUBLIC_HTTPS_PORT=443 \
  PUBLIC_WS_PORT=443 \
  UNMS_NETFLOW_PORT=2055 \
  SECURE_LINK_SECRET=enigma \
  SSL_CERT=""

EXPOSE 80 443

VOLUME ["/config"]

COPY root /
