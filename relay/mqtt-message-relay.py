import paho.mqtt.client as mqtt
import paho.mqtt.publish as publish
import paho.mqtt.subscribe as subscribe

gateways = []

def on_connect(_mqttc, obj, flags, status):
    print("connected: status=%s" % (status))
    return

def on_publish(_mqttc, obj, mid):
    print("mid: " + str(mid))
    return

def on_subscribe(_mqttc, obj, mid, granted_qos):
    print("Subscribed: " + str(mid) + " " + str(granted_qos))
    return

def on_log(_mqttc, obj, level, string):
    print(string)
    return

def on_message(_mqttc, obj, msg):
    url = msg.topic.split('/')
    print('URL:')
    print(url)
    typeId = url[2]
    deviceId = url[4]
    event = url[6]
    msg_format = url[8]

    if deviceId not in gateways:
        gateways.append(deviceId)

    #Support ping event and events identified by intended recipient
    if event == 'ping':

        if deviceId == 'test-gw-0':
            sendDeviceId = 'test-gw-1'
        if deviceId == 'test-gw-1':
            sendDeviceId = 'test-gw-0'
        if deviceId == 'test-gw-2':
            sendDeviceId = 'test-gw-3'
        if deviceId == 'test-gw-3':
            sendDeviceId = 'test-gw-2'
        if deviceId == 'test-gw-4':
            sendDeviceId = 'test-gw-5'
        if deviceId == 'test-gw-5':
            sendDeviceId = 'test-gw-04'
    else:
        sendDeviceId = event

    relay_topic = 'iot-2/type/'+typeId+'/id/'+sendDeviceId+'/cmd/message/fmt/'+msg_format
    send_url = relay_topic .split('/')
    print('Send URL:')
    print(send_url)
    _mqttc.publish(relay_topic, msg.payload)
    return

mqttc = mqtt.Client('a:4tlin1:a2g6k39sl6r5')
mqttc.username_pw_set('a-4tlin1-j3fhzvb4i4', password='aZ2HlOA10+OcLYh7mV')

mqttc.on_connect = on_connect
mqttc.on_subscribe = on_subscribe
mqttc.on_message = on_message

mqttc.connect(host='4tlin1.messaging.internetofthings.ibmcloud.com', port=1883, keepalive=60)

mqttc.subscribe('iot-2/type/+/id/+/evt/+/fmt/+', 0)

mqttc.loop_forever()